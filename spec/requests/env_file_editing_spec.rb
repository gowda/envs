require "rails_helper"

RSpec.describe "Editing and publishing S3 files", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:bucket) { "invented-bucket" }
  let(:client) { Aws::S3::Client.new(stub_responses: true, region: "us-east-1") }
  let(:text) { "FIRST=one\nSAME=first\nSAME=second\nBARE\nLAST=end\n" }
  let!(:file) { EnvFile.create!(bucket: bucket, key: "invented.env", content: text, etag: '"old-etag"', fetched_at: Time.current) }

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
    client.stub_responses(:head_object, content_type: "text/plain", metadata: { "invented" => "metadata" },
      server_side_encryption: "aws:kms", ssekms_key_id: "invented-kms-key")
    client.stub_responses(:put_object, etag: '"new-etag"')
  end

  def document
    Nokogiri::HTML5(response.body)
  end

  def save(value, line: 1)
    post edit_s3_variable_path(file, line_number: line), params: { value: value }
  end

  def show_file
    get s3_file_path(file)
  end

  def publish_request
    client.api_requests.find { |request| request[:operation_name] == :put_object }&.fetch(:params)
  end

  it "saves, updates, reverts and discards encrypted local edits with row and card labels" do
    show_file
    expect(document.at_css("button[disabled]").text).to eq("Review & publish")
    expect(document.css('a').count { |link| link.text == "Edit" }).to eq(4)
    get edit_s3_variable_path(file, line_number: 1)
    expect(response.headers["Cache-Control"]).to eq("no-store")
    expect(document.at_css('input[name="value"]')["value"]).to eq("one")
    expect(document.at_css('a.btn')["href"]).to eq(s3_file_path(file))
    expect(PendingEdit.count).to eq(0)

    save("invented-private-value")
    expect(response).to redirect_to(s3_file_path(file))
    edit = PendingEdit.first!
    expect(edit.attributes.slice("name", "occurrence", "value"))
      .to eq("name" => "FIRST", "occurrence" => 1, "value" => "invented-private-value")
    raw = PendingEdit.connection.select_value("SELECT value FROM pending_edits WHERE id = #{edit.id.to_i}")
    expect(raw).not_to include("invented-private-value")
    expect(JSON.parse(raw)).to have_key("p")
    expect(edit.inspect).not_to include("invented-private-value")
    expect(file.reload.content).to eq(text)
    show_file
    expect(document.at_css("section .Box-row").text).to include("invented-private-value", "Modified")
    expect(document.at_css('a.btn-primary')["href"]).to eq(review_s3_file_path(file))
    get s3_path
    expect(document.at_css("a.Box").text).to include("Modified")
    expect(document.at_css("a.Box").text).not_to include("invented-private-value")
    get edit_s3_variable_path(file, line_number: 1)
    expect(document.at_css('input[name="value"]')["value"]).to eq("invented-private-value")

    save("changed-again")
    expect(PendingEdit.count).to eq(1)
    expect(edit.reload.value).to eq("changed-again")
    save("one")
    expect(PendingEdit.count).to eq(0)
    save("discard-me")
    save("discard-second", line: 3)
    post discard_s3_changes_path(file)
    expect(response).to redirect_to(s3_file_path(file))
    expect(PendingEdit.count).to eq(0)
    get s3_path
    expect(document.at_css("a.Box").text).not_to include("Modified")
  end

  [ '"quotes" and \'single\' # comment = $PATH', " \t padded \t ", "", "invented-é" ].each do |value|
    it "stores and publishes #{value.inspect} exactly" do
      save(value)
      expect(response).to redirect_to(s3_file_path(file))
      expect(PendingEdit.first!.value).to eq(value)
      show_file
      expect(document.at_css(".variable-value").text).to eq(value)
      expect(document.at_css("section .Box-row").text.include?("Leading or trailing whitespace"))
        .to eq(value.match?(/\A[ \t]|[ \t]\z/))
      post publish_s3_file_path(file)
      expect(publish_request[:body].b).to eq(text.sub("FIRST=one", "FIRST=#{value}").b)
    end
  end

  [ [ "a\nb", "CR or LF" ], [ "a\rb", "CR or LF" ], [ "a\r\nb", "CR or LF" ],
    [ "a" * 65_531, "65,536 bytes" ] ].each do |value, reason|
    it "rejects #{reason} before saving" do
      save(value)
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.headers["Cache-Control"]).to eq("no-store")
      expect(document.at_css(".flash-error").text).to include(reason)
      expect(PendingEdit.count).to eq(0)
      expect(file.reload.content).to eq(text)
    end
  end

  it "rejects invalid UTF-8 on the edit page" do
    post edit_s3_variable_path(file, line_number: 1), params: "value=%FF",
      headers: { "CONTENT_TYPE" => "application/x-www-form-urlencoded" }
    expect(response).to have_http_status(:unprocessable_content)
    expect(document.at_css(".flash-error").text).to include("valid UTF-8")
    expect(PendingEdit.count).to eq(0)
  end

  it "keeps an existing edit when a replacement is invalid" do
    save("kept-value")
    save("invalid\nvalue")
    expect(response).to have_http_status(:unprocessable_content)
    expect(PendingEdit.first!.value).to eq("kept-value")
  end

  it "edits only the second occurrence and preserves every other byte" do
    original = "\uFEFF  SAME=first\r\n# invented comment\n\tSAME=second\r\nOTHER=last".b
    file.update!(content: original)
    save('"new" # = $VALUE', line: 3)
    expect(PendingEdit.first!.occurrence).to eq(2)
    post publish_s3_file_path(file)
    expect(publish_request[:body].b).to eq(original.sub("second", '"new" # = $VALUE'))
    expect(file.reload.content.b).to eq(publish_request[:body].b)
  end

  it "preserves a BOM prefix and a missing final newline when editing those lines" do
    original = "\uFEFF  FIRST=one\r\n# keep\n\tLAST=last".b
    file.update!(content: original)
    save("first-change", line: 1)
    save("last-change", line: 3)
    get review_s3_file_path(file)
    expect(response).to have_http_status(:ok)
    post publish_s3_file_path(file)
    expect(publish_request[:body].b).to eq("\uFEFF  FIRST=first-change\r\n# keep\n\tLAST=last-change".b)
  end

  it "rolls back reconciled edits when a later download fails" do
    save("kept-edit")
    client.stub_responses(:list_objects_v2, contents: [ { key: file.key, size: 40 }, { key: "other.env", size: 40 } ])
    client.stub_responses(:get_object, [ { body: "FIRST=kept-edit\n", etag: '"remote"' }, "AccessDenied" ])
    post refresh_s3_path
    expect(file.reload.content).to eq(text)
    expect(PendingEdit.first!.value).to eq("kept-edit")
  end

  it "keeps edits when head_object fails before the write" do
    save("kept-edit")
    client.stub_responses(:head_object, "AccessDenied")
    post publish_s3_file_path(file)
    follow_redirect!
    expect(document.at_css(".flash-error").text).to eq("S3 publish failed (AccessDenied).")
    expect(publish_request).to be_nil
    expect(PendingEdit.first!.value).to eq("kept-edit")
    expect(file.reload.content).to eq(text)
  end

  it "refuses a publish with no ETag or no changes" do
    post publish_s3_file_path(file)
    expect(response).to redirect_to(s3_file_path(file))
    save("kept-edit")
    file.update!(etag: nil)
    post publish_s3_file_path(file)
    follow_redirect!
    expect(document.at_css(".flash-error").text).to include("ETag")
    expect(publish_request).to be_nil
    expect(PendingEdit.first!.value).to eq("kept-edit")
  end

  it "shows three context lines, line numbers, markers and diff classes" do
    file.update!(content: (1..16).map { |number| "KEY#{number}=old#{number}\n" }.join)
    save("new5", line: 5)
    save("new14", line: 14)
    get review_s3_file_path(file)
    expect(response).to have_http_status(:ok)
    expect(response.headers["Cache-Control"]).to eq("no-store")
    rows = document.css("tbody tr")
    expect(rows.map { |row| row["class"] }).to eq(
      [ *([ "diff-context" ] * 3), "diff-deletion", "diff-addition", *([ "diff-context" ] * 3), "diff-gap",
        *([ "diff-context" ] * 3), "diff-deletion", "diff-addition", *([ "diff-context" ] * 2) ])
    expect(rows.first.css("td").map(&:text)).to eq([ "2", "2", " ", "KEY2=old2" ])
    expect(document.at_css(".diff-deletion").css("td").map(&:text)).to eq([ "5", "", "-", "KEY5=old5" ])
    expect(document.at_css(".diff-addition").css("td").map(&:text)).to eq([ "", "5", "+", "KEY5=new5" ])
    expect(document.css("script").map { |tag| tag["type"] }).to eq(%w[importmap module])
  end

  it "publishes with the ETag and repeated settings, updates the snapshot and deletes edits" do
    save("published")
    post publish_s3_file_path(file)
    expect(response).to redirect_to(s3_file_path(file))
    expect(publish_request).to include(bucket: bucket, key: file.key, body: text.sub("one", "published"),
      if_match: '"old-etag"', content_type: "text/plain", metadata: { "invented" => "metadata" },
      server_side_encryption: "aws:kms", ssekms_key_id: "invented-kms-key")
    expect(file.reload.attributes.slice("content", "etag", "last_modified", "fetched_at"))
      .to eq("content" => text.sub("one", "published"), "etag" => '"new-etag"',
        "last_modified" => Time.current, "fetched_at" => Time.current)
    expect(PendingEdit.count).to eq(0)
    follow_redirect!
    expect(document.at_css(".flash-success").text).to include("Published")
  end

  %w[PreconditionFailed AccessDenied].each do |code|
    it "keeps the snapshot and edits on #{code}" do
      save("kept-edit")
      snapshot = file.reload.attributes
      edit = PendingEdit.first!.attributes
      client.stub_responses(:put_object, code)
      post publish_s3_file_path(file)
      follow_redirect!
      message = document.at_css(".flash-error").text
      expect(message).to include(code == "PreconditionFailed" ? "file changed in S3" : "S3 publish failed (AccessDenied)")
      expect(message).to include("Refresh") if code == "PreconditionFailed"
      expect(file.reload.attributes).to eq(snapshot)
      expect(PendingEdit.first!.attributes).to eq(edit)
    end
  end

  it "does not permit editing invalid files, large files or bare names" do
    get edit_s3_variable_path(file, line_number: 4)
    expect(response).to have_http_status(:not_found)
    [ { content: "INVALID NAME=value" }, { content: nil, too_large: true } ].each do |attributes|
      file.update!(attributes)
      show_file
      expect(document.css("a").map(&:text)).not_to include("Edit")
      save("attempted")
      expect(response).to redirect_to(s3_file_path(file))
      expect(PendingEdit.count).to eq(0)
    end
  end

  [ [ "FIRST=remote\nSAME=first\nSAME=second\n", true ],
    [ "FIRST=remote\nSAME=first\n", false ],
    [ "FIRST=remote\nSAME=first\nSAME=kept-edit\n", false ] ].each do |new_text, kept|
    it "reconciles a refreshed occurrence: #{new_text.inspect}" do
      save("kept-edit", line: 3)
      client.stub_responses(:list_objects_v2, contents: [ { key: file.key, size: new_text.bytesize } ])
      client.stub_responses(:get_object, body: new_text, etag: '"refreshed"')
      post refresh_s3_path
      expect(file.reload.content).to eq(new_text)
      expect(PendingEdit.exists?).to eq(kept)
    end
  end

  it "deletes edits when the refreshed file is gone" do
    save("kept-edit")
    client.stub_responses(:list_objects_v2, contents: [])
    post refresh_s3_path
    expect(EnvFile.exists?(file.id)).to be(false)
    expect(PendingEdit.count).to eq(0)
  end

  it "filters the value parameter and encrypted changes from logs" do
    output = StringIO.new
    logger = ActiveSupport::Logger.new(output)
    original = ActiveRecord::Base.logger
    ActiveRecord::Base.logger = logger
    allow(Rails).to receive(:logger).and_return(logger)
    save("invented-sensitive-edit")
    expect(ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
      .filter("value" => "invented-sensitive-edit")).to eq("value" => "[FILTERED]")
    expect(output.string).not_to include("invented-sensitive-edit")
  ensure
    ActiveRecord::Base.logger = original
  end
end
