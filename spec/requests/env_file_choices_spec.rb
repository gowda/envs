require "rails_helper"

RSpec.describe "Resolving repeated names", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:bucket) { "invented-bucket" }
  let(:client) { Aws::S3::Client.new(stub_responses: true, region: "us-east-1") }
  let(:text) { "# keep\nSAME=first\nOTHER=unchanged\nSAME=middle\nSAME=last\nTAIL=end\n" }
  let!(:file) { create_env_file(bucket: bucket, key: "invented.env", content: text, etag: '"old"', fetched_at: Time.current) }

  around do |example|
    previous = ENV["ENVS_S3_BUCKET"]
    ENV["ENVS_S3_BUCKET"] = bucket
    travel_to(Time.utc(2026, 11, 14, 12)) { example.run }
  ensure
    previous ? ENV["ENVS_S3_BUCKET"] = previous : ENV.delete("ENVS_S3_BUCKET")
  end

  before do
    allow(EnvFilePublish).to receive(:client).and_return(client)
    allow(EnvFileRefresh).to receive(:client).and_return(client)
    client.stub_responses(:put_object, etag: '"new"')
  end

  def document
    Nokogiri::HTML5(response.body)
  end

  def choose(line, name: "SAME", count: 3)
    post s3_variable_choice_path(file), params: { name: name, line_number: line, line_count: count }
  end

  def edit(value, name: "SAME")
    post edit_s3_variable_path(file), params: { name: name, value: value, etag: file.reload.etag }
  end

  def put_body
    client.api_requests.find { |request| request[:operation_name] == :put_object }&.dig(:params, :body)
  end

  def refresh_to(content)
    client.stub_responses(:list_objects_v2, contents: [ { key: file.key, size: content.bytesize } ])
    client.stub_responses(:get_object, body: content, etag: '"refreshed"')
    post refresh_s3_path
  end

  it "offers Resolve on S3, lists the lines and defaults to the last without putting a value in a URL" do
    name = "API/KEY.part?"
    update_env_file(file, content: text.gsub("SAME", name))
    get s3_file_path(file)
    link = document.css('a').find { |node| node.text == "Resolve" }
    uri = URI.parse(link["href"])
    expect(uri.path).to eq(s3_variable_choice_path(file))
    expect(URI.decode_www_form(uri.query).to_h).to eq("name" => name)
    get link["href"]
    expect(response).to have_http_status(:ok)
    expect(response.headers["Cache-Control"]).to eq("no-store")
    expect(document.css("fieldset .Box-row").map { |row| row.text.squish }).to eq([
      "Line 2: first", "Line 4: middle", "Line 5: last"
    ])
    expect(document.css('input[type="radio"]').map { |radio| radio["value"] }).to eq(%w[2 4 5])
    expect(document.at_css('input[checked]')["value"]).to eq("5")
    expect(document.at_css('input[name="name"]')["value"]).to eq(name)
    expect(document.at_css('input[name="line_count"]')["value"]).to eq("3")
    expect(document.at_css("main form")["action"]).to eq(s3_variable_choice_path(file))
    expect(document.css("a, form").map { |node| node["href"] || node["action"] }.join).not_to match(/first|middle|last/)
    expect(document.css("a").find { |node| node.text == "Cancel" }["href"]).to eq(s3_file_path(file))
    expect(PendingChoice.count).to eq(0)
    expect(document.css("script").map { |node| node["type"] }).to eq(%w[importmap module])
    choose(2, name: name)
    expect(file.pending_choices.first!.name).to eq(name)
  end

  it "offers no Resolve for an uploaded file" do
    upload = Rack::Test::UploadedFile.new(StringIO.new(text), "text/plain", true, original_filename: "invented.env")
    post files_path, params: { file: upload }
    follow_redirect!
    expect(response).to have_http_status(:ok)
    expect(document.at_css('[aria-label="Repeated names"]')).not_to be_nil
    expect(document.css("a").map(&:text)).not_to include("Resolve", "Change", "Edit")
  end

  it "saves, changes and deletes one choice, with the selected default, labels and links" do
    choose(2)
    expect(response).to redirect_to(s3_file_path(file))
    expect(PendingChoice.count).to eq(1)
    expect(snapshot_entries(file)).to eq(entries_from(text))
    get s3_variable_choice_path(file, name: "SAME")
    expect(document.at_css('input[checked]')["value"]).to eq("2")
    delete_form = document.css("main form").find { |form| form.text.include?("Keep every line") }
    expect(delete_form.at_css('input[name="name"]')["value"]).to eq("SAME")
    get s3_file_path(file)
    expect(document.at_css('[aria-label="Repeated names"]').text.squish)
      .to include("Line 2 stays. A publish removes lines 4 and 5.", "Change")
    rows = document.css("section .Box-row").select { |row| row.at_css(".text-bold").text == "SAME" }
    expect(rows.map { |row| row.css(".Label").map(&:text) }).to eq([ [], [ "Removed" ], [ "Removed" ] ])
    expect(rows.map { |row| row.css("a").map(&:text) }).to eq([ [ "Edit" ], [], [] ])
    expect(document.css("a").map(&:text)).to include("Review & publish")
    get s3_path
    expect(document.at_css("a.Box").text).to include("Modified")
    choose(4)
    expect(PendingChoice.count).to eq(1)
    get s3_variable_choice_path(file, name: "SAME")
    expect(document.at_css('input[checked]')["value"]).to eq("4")
    delete s3_variable_choice_path(file), params: { name: "SAME" }
    expect(response).to redirect_to(s3_file_path(file))
    expect(PendingChoice.count).to eq(0)
    get s3_file_path(file)
    expect(document.css(".Label").map(&:text)).not_to include("Removed")
    expect(document.css(".Label").map(&:text).count("Overridden")).to eq(2)
    get s3_path
    expect(document.at_css("a.Box").text).not_to include("Modified")
  end

  [ [ 2, "first" ], [ 4, "middle" ], [ 5, "last" ] ].each do |line, value|
    it "keeps line #{line} of three and changes only its value" do
      choose(line)
      edit("edited")
      get edit_s3_variable_path(file, name: "SAME")
      expect(document.at_css('input[name="value"]')["value"]).to eq("edited")
      post publish_s3_file_path(file)
      expected = "# keep\n#{line == 2 ? "SAME=edited\n" : ""}OTHER=unchanged\n#{line != 2 ? "SAME=edited\n" : ""}TAIL=end\n"
      expect(put_body).to eq(expected)
      expect(snapshot_entries(file)).to eq(entries_from(expected))
      expect(file.etag).to eq('"new"')
      expect(file.fetched_at).to eq(Time.current)
      expect(file.last_modified).to eq(Time.current)
      expect(PendingChoice.count).to eq(0)
      expect(PendingEdit.count).to eq(0)
      expect(EnvFileContents.call(expected).entries.find { |entry| entry.name == "SAME" }.value).not_to eq(value)
    end
  end

  it "publishes choices for two names without any value edits" do
    update_env_file(file, content: "A=one\nB=two\nA=three\nB=four\nB=five\n")
    choose(1, name: "A", count: 2)
    choose(4, name: "B")
    post publish_s3_file_path(file)
    expect(put_body).to eq("A=one\nB=four\n")
    expect(snapshot_entries(file)).to eq(entries_from(put_body))
    expect(PendingChoice.count).to eq(0)
  end

  it "does not save a choice for a unique name, invalid file, or an unrelated line" do
    choose(3, name: "OTHER", count: 1)
    expect(PendingChoice.count).to eq(0)
    choose(3)
    expect(PendingChoice.count).to eq(0)
    [ { content: "INVALID NAME=value\n" }, { content: nil, too_large: true } ].each do |attributes|
      update_env_file(file, **attributes)
      choose(2)
      expect(response).to redirect_to(s3_file_path(file))
      expect(PendingChoice.count).to eq(0)
    end
  end

  [ "SAME=one\nOTHER=two\n", "SAME=one\nSAME=two\nSAME=three\nSAME=four\n" ].each do |content|
    it "saves nothing after the count changes to #{content.lines.size}" do
      choose(2)
      previous = PendingChoice.first!.attributes
      get s3_variable_choice_path(file, name: "SAME")
      update_env_file(file, content: content)
      choose(4)
      expect(response).to redirect_to(s3_file_path(file))
      expect(flash[:alert]).to eq("The lines changed. Refresh the file.")
      expect(PendingChoice.first!.attributes).to eq(previous)
    end
  end

  it "moves a value edit to the kept line and removes redundant edits on save, change and delete" do
    edit("middle")
    choose(2)
    expect(PendingEdit.first!.value).to eq("middle")
    get s3_file_path(file)
    expect(document.css("section .variable-value").map(&:text)).to eq(%w[middle unchanged middle last end])
    choose(4)
    expect(PendingEdit.count).to eq(0)
    edit("last")
    delete s3_variable_choice_path(file), params: { name: "SAME" }
    expect(PendingEdit.count).to eq(0)
    edit("first")
    choose(2)
    expect(PendingEdit.count).to eq(0)
    edit("first")
    expect(PendingEdit.count).to eq(0)
  end

  it "preserves all other bytes, including the BOM, CRLF, indentation and an absent final newline" do
    original = "\uFEFFSAME=first\r\n# unchanged\r\n  SAME=middle\r\n\tOTHER=literal # = \r\nSAME=last".b
    update_env_file(file, content: original)
    choose(3)
    edit("new")
    result = EnvFileRewrite.rewrite(file.reload, text: original)
    expect(result.text.b).to eq("\uFEFF# unchanged\r\n  SAME=new\r\n\tOTHER=literal # = \r\n".b)
    expect(result.operations.map(&:kind)).to eq(%i[remove change change keep remove])
    expect(result.operations.map(&:old_text).join.b).to eq(original)
    expect(result.operations.map(&:new_text).join.b).to eq(result.text.b)
    post publish_s3_file_path(file)
    expect(put_body.b).to eq(result.text.b)
  end

  it "shows removed, changed and unchanged review rows with old and new numbers" do
    choose(4)
    edit("changed")
    get review_s3_file_path(file)
    expect(response).to have_http_status(:ok)
    expect(response.headers["Cache-Control"]).to eq("no-store")
    expect(document.css("tbody tr").map { |row| [ row["class"], *row.css("td").map(&:text) ] }).to eq([
      [ "diff-context", "1", "1", " ", "# keep" ],
      [ "diff-deletion", "2", "", "-", "SAME=first" ],
      [ "diff-context", "3", "2", " ", "OTHER=unchanged" ],
      [ "diff-deletion", "4", "", "-", "SAME=middle" ],
      [ "diff-addition", "", "3", "+", "SAME=changed" ],
      [ "diff-deletion", "5", "", "-", "SAME=last" ],
      [ "diff-context", "6", "4", " ", "TAIL=end" ]
    ])
    expect(document.css("button").map(&:text)).to include("Publish")
  end

  it "keeps both kinds of pending change and the snapshot on a stale ETag" do
    choose(4)
    edit("changed")
    previous = [ file.reload.attributes, PendingChoice.first!.attributes, PendingEdit.first!.attributes ]
    client.stub_responses(:put_object, "PreconditionFailed")
    client.stub_responses(:get_object, body: text, etag: file.etag, last_modified: file.last_modified)
    post publish_s3_file_path(file)
    expect(flash[:alert]).to include("file changed in S3")
    expect([ file.reload.attributes, PendingChoice.first!.attributes, PendingEdit.first!.attributes ]).to eq(previous)
  end

  it "discards choices and edits together" do
    choose(2)
    edit("changed")
    post discard_s3_changes_path(file)
    expect(PendingChoice.count).to eq(0)
    expect(PendingEdit.count).to eq(0)
    expect(snapshot_entries(file)).to eq(entries_from(text))
  end

  it "keeps a choice through refresh with the same count, even with a preceding line" do
    choose(4)
    refresh_to("PREFIX=added\n" + text)
    expect(PendingChoice.count).to eq(1)
    get s3_variable_choice_path(file, name: "SAME")
    expect(document.at_css('input[checked]')["value"]).to eq("5")
  end

  it "keeps a conflicting choice and reconciles the value edit against the last line" do
    choose(2)
    edit("last")
    refresh_to("SAME=first\nSAME=last\n")
    expect(PendingChoice.count).to eq(1)
    expect(PendingEdit.count).to eq(0)
  end

  it "keeps a choice when refresh removes the file" do
    choose(2)
    client.stub_responses(:list_objects_v2, contents: [])
    post refresh_s3_path
    expect(file.reload).to be_deleted_in_s3
    expect(PendingChoice.count).to eq(1)
  end

  it "does not log the displayed values when choosing a line" do
    output = StringIO.new
    logger = ActiveSupport::Logger.new(output)
    original = ActiveRecord::Base.logger
    ActiveRecord::Base.logger = logger
    allow(Rails).to receive(:logger).and_return(logger)
    get s3_variable_choice_path(file, name: "SAME")
    choose(2)
    expect(output.string).not_to include("SAME=first", "SAME=middle", "SAME=last")
  ensure
    ActiveRecord::Base.logger = original
  end
end
