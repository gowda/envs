require "rails_helper"

RSpec.describe "S3 conflicts", type: :request do
  let(:bucket) { "invented-bucket" }
  let(:client) { Aws::S3::Client.new(stub_responses: true, region: "us-east-1") }
  let(:text) { "FIRST=base-one\nSAME=first\nSAME=last\nOTHER=untouched\n" }
  let!(:file) { create_env_file(bucket: bucket, key: "invented.env", content: text, etag: '"old"', fetched_at: Time.current) }

  around do |example|
    previous = ENV["ENVS_S3_BUCKET"]
    ENV["ENVS_S3_BUCKET"] = bucket
    example.run
  ensure
    previous ? ENV["ENVS_S3_BUCKET"] = previous : ENV.delete("ENVS_S3_BUCKET")
  end

  before do
    allow(EnvFileRefresh).to receive(:client).and_return(client)
    allow(EnvFilePublish).to receive(:client).and_return(client)
    client.stub_responses(:put_object, etag: '"published"')
  end

  def document
    Nokogiri::HTML5(response.body)
  end

  def edit(value = "local-one", name: "FIRST", etag: file.reload.etag)
    post edit_s3_variable_path(file), params: { name: name, value: value, etag: etag }
  end

  def choose(line = 2, count: 2)
    post s3_variable_choice_path(file), params: { name: "SAME", line_number: line, line_count: count }
  end

  def refresh_to(content)
    client.stub_responses(:list_objects_v2, contents: [ { key: file.key, size: content.bytesize } ])
    client.stub_responses(:get_object, body: content, etag: '"refreshed"')
    post refresh_s3_path
    get s3_file_path(file)
  end

  def conflict_box
    document.at_css('[aria-label="Conflicts"]')
  end

  def row(name)
    document.css('[aria-label="Variables"] .Box-row').find { |node| node.at_css(".text-bold").text == name }
  end

  def put_requests
    client.api_requests.select { |request| request[:operation_name] == :put_object }
  end

  it "does not require action for S3 changes without a pending change" do
    refresh_to(text.sub("base-one", "remote-one"))
    expect(conflict_box).to be_nil
    expect(row("FIRST").text).to include("remote-one")
    expect(EnvFileConflicts.new(file.reload)).not_to be_any
    edit
    refresh_to(text.sub("base-one", "remote-one").sub("untouched", "remote-other"))
    expect(conflict_box).to be_nil
    expect(row("FIRST").text).to include("local-one")
  end

  it "keeps a conflicting value edit and labels the box, row and card" do
    edit
    refresh_to(text.sub("base-one", "remote-one"))
    expect(file.pending_edits.first!.value).to eq("local-one")
    expect(conflict_box.text.squish).to include("FIRST changed in S3 after you edited it.")
    expect(conflict_box.at_css("a")["href"]).to eq(edit_s3_variable_path(file, name: "FIRST"))
    expect(row("FIRST").css(".Label").map(&:text)).to include("Conflict", "Modified")
    expect(document.at_css("button[disabled]").text).to eq("Review & publish")
    get s3_path
    expect(document.at_css("a.Box").css(".Label").map(&:text)).to include("Conflict", "Modified")
  end

  it "deletes an edit only when its current line already holds the requested value" do
    edit
    refresh_to(text.sub("base-one", "local-one"))
    expect(PendingEdit.count).to eq(0)
    expect(conflict_box).to be_nil
  end

  it "keeps an edit for a missing name and discards it through a form" do
    edit
    refresh_to(text.lines.drop(1).join)
    expect(PendingEdit.count).to eq(1)
    expect(conflict_box.text.squish).to include("FIRST is no longer in the file in S3.")
    form = conflict_box.at_css("form")
    expect(form.at_css('input[name="name"]')["value"]).to eq("FIRST")
    expect(form.at_css("button").text).to eq("Discard the change")
    expect(form["action"]).to eq(edit_s3_variable_path(file))
    delete form["action"], params: { name: "FIRST" }
    expect(response).to redirect_to(s3_file_path(file))
    expect(response.headers["Cache-Control"]).to eq("no-store")
    expect(PendingEdit.count).to eq(0)
  end

  [ "INVALID NAME=value\n", "KEY=" + "a" * EnvFileContents::MAX_BYTES ].each do |content|
    it "keeps every pending change through an unreadable snapshot and back to a valid snapshot of #{content.bytesize} bytes" do
      edit
      choose
      previous = [ PendingEdit.first!.attributes, PendingChoice.first!.attributes ]
      refresh_to(content)
      expect(document.at_css(".flash-error")).not_to be_nil
      expect(conflict_box).to be_nil
      expect([ PendingEdit.first!.attributes, PendingChoice.first!.attributes ]).to eq(previous)
      refresh_to(text.sub("base-one", "remote-one").sub("first", "remote-first"))
      expect([ PendingEdit.first!.attributes, PendingChoice.first!.attributes ]).to eq(previous)
      expect(conflict_box.css(".Box-row").size).to eq(2)
    end
  end

  [ "SAME=first\nSAME=last\nSAME=added\n", "SAME=changed\nSAME=last\n" ].each do |lines|
    it "keeps a choice and treats it as unchosen when S3 now has #{lines.inspect}" do
      choose
      refresh_to("FIRST=base-one\n" + lines)
      expect(PendingChoice.count).to eq(1)
      expect(conflict_box.text.squish).to include("The lines with SAME changed in S3.")
      expect(document.css(".Label").map(&:text)).not_to include("Removed")
      expect(document.at_css('[aria-label="Repeated names"]').text.squish).to include("Only line #{lines.lines.size + 1} takes effect.")
      expect(EnvFileRewrite.entries(file.reload).fetch("SAME").value).to eq(lines.lines.last.chomp.split("=").last)
      get s3_variable_choice_path(file, name: "SAME")
      expect(document.text).to include("The lines changed in S3. Choose again.")
      expect(document.at_css("input[checked]")["value"]).to eq((lines.lines.size + 1).to_s)
      choose(2, count: lines.lines.size)
      expect(PendingChoice.first!.base_values).to eq(lines.lines.map { |line| line.chomp.split("=").last })
      get s3_file_path(file)
      expect(conflict_box).to be_nil
      expect(document.css(".Label").map(&:text)).to include("Removed")
    end
  end

  [ "SAME=only\n", "OTHER=only\n" ].each do |content|
    it "offers to discard a choice when the name is no longer repeated: #{content.inspect}" do
      choose
      refresh_to(content)
      expect(conflict_box.text.squish).to include("SAME is no longer repeated in S3.")
      expect(conflict_box.at_css("button").text).to eq("Discard the choice")
      expect(conflict_box.at_css('input[name="name"]')["value"]).to eq("SAME")
      delete s3_variable_choice_path(file), params: { name: "SAME" }
      expect(PendingChoice.count).to eq(0)
    end
  end

  it "shows three values and saves the user's resolution with the current base" do
    edit
    refresh_to(text.sub("base-one", "remote-one"))
    get edit_s3_variable_path(file, name: "FIRST")
    expect(response.headers["Cache-Control"]).to eq("no-store")
    expect(document.text).to include("Value when you edited: base-one", "Value in S3 now: remote-one")
    expect(document.at_css('input[name="value"]')["value"]).to eq("local-one")
    expect(document.at_css('input[name="etag"]')["value"]).to eq('"refreshed"')
    expect(document.css("a, form").map { |node| node["href"] || node["action"] }.join).not_to match(/base-one|remote-one|local-one/)
    edit("local-one")
    expect(response).to redirect_to(s3_file_path(file))
    expect(PendingEdit.first!.attributes).to include("value" => "local-one", "base_value" => "remote-one")
    get s3_file_path(file)
    expect(conflict_box).to be_nil
  end

  [ false, true ].each do |conflict|
    it "uses the S3 value by removing only that edit, with conflict #{conflict}" do
      edit
      edit("other-local", name: "OTHER")
      refresh_to(text.sub("base-one", "remote-one")) if conflict
      get edit_s3_variable_path(file, name: "FIRST")
      form = document.css("main form").find { |node| node.text.include?("Use the S3 value") }
      expect(form.at_css('input[name="name"]')["value"]).to eq("FIRST")
      delete form["action"], params: { name: "FIRST" }
      expect(PendingEdit.pluck(:name)).to eq([ "OTHER" ])
      get s3_file_path(file)
      expect(row("FIRST").at_css(".variable-value").text).to eq(conflict ? "remote-one" : "base-one")
    end
  end

  it "keeps the typed value on a stale form with the current conflict values and ETag" do
    edit
    get edit_s3_variable_path(file, name: "FIRST")
    etag = document.at_css('input[name="etag"]')["value"]
    refresh_to(text.sub("base-one", "remote-one"))
    previous = PendingEdit.first!.attributes
    output = StringIO.new
    logger = ActiveSupport::Logger.new(output)
    original_logger = ActiveRecord::Base.logger
    ActiveRecord::Base.logger = logger
    allow(Rails).to receive(:logger).and_return(logger)
    edit("invented-typed", etag: etag)
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.headers["Cache-Control"]).to eq("no-store")
    expect(document.text).to include("The file changed in S3. Check the value and save again.", "remote-one", "base-one")
    expect(document.at_css('input[name="value"]')["value"]).to eq("invented-typed")
    expect(document.at_css('input[name="etag"]')["value"]).to eq('"refreshed"')
    expect(PendingEdit.first!.attributes).to eq(previous)
    expect(document.css("a, form").map { |node| node["href"] || node["action"] }.join).not_to include("invented-typed")
    expect(output.string).not_to include("invented-typed")
  ensure
    ActiveRecord::Base.logger = original_logger
  end

  it "saves no new edit from a stale form" do
    get edit_s3_variable_path(file, name: "FIRST")
    etag = document.at_css('input[name="etag"]')["value"]
    refresh_to(text.sub("base-one", "remote-one"))
    edit("unsaved-local", etag: etag)
    expect(response).to have_http_status(:unprocessable_content)
    expect(document.text).to include("The file changed in S3. Check the value and save again.")
    expect(document.at_css('input[name="value"]')["value"]).to eq("unsaved-local")
    expect(PendingEdit.count).to eq(0)
  end

  it "scrubs invalid UTF-8 in a typed value on a stale save" do
    edit
    previous = PendingEdit.first!.attributes
    refresh_to(text.sub("base-one", "remote-one"))
    post edit_s3_variable_path(file), params: "name=FIRST&value=invented-%FF&etag=%22old%22",
      headers: { "CONTENT_TYPE" => "application/x-www-form-urlencoded" }
    expect(response).to have_http_status(:unprocessable_content)
    expect(document.text).to include("The file changed in S3. Check the value and save again.")
    expect(document.at_css('input[name="value"]')["value"]).to eq("invented-\uFFFD")
    expect(document.at_css('input[name="etag"]')["value"]).to eq('"refreshed"')
    expect(PendingEdit.first!.attributes).to eq(previous)
  end

  it "keeps every line to resolve a conflicting choice" do
    choose
    refresh_to(text.sub("first", "remote-first"))
    get s3_variable_choice_path(file, name: "SAME")
    expect(document.text).to include("The lines changed in S3. Choose again.")
    expect(document.at_css("input[checked]")["value"]).to eq("3")
    form = document.css("main form").find { |node| node.text.include?("Keep every line") }
    delete form["action"], params: { name: "SAME" }
    expect(PendingChoice.count).to eq(0)
    get s3_file_path(file)
    expect(conflict_box).to be_nil
  end

  [ false, true ].each do |conflict|
    it "changes the base of a value edit with a choice only if the edit was not in conflict: #{conflict}" do
      edit("local-same", name: "SAME")
      refresh_to(text.sub("SAME=last", "SAME=remote-last")) if conflict
      choose
      expect(PendingEdit.first!.base_value).to eq(conflict ? "last" : "first")
      choose(3)
      expect(PendingEdit.first!.base_value).to eq("last")
      delete s3_variable_choice_path(file), params: { name: "SAME" }
      expect(PendingEdit.first!.base_value).to eq("last")
      expect(EnvFileConflicts.new(file.reload).edit_conflict?(PendingEdit.first!)).to eq(conflict)
    end
  end

  it "refuses rewriting, reviewing and publishing conflicts before calling S3, then publishes the resolved body" do
    edit
    choose
    refresh_to(text.sub("base-one", "remote-one").sub("first", "remote-first"))
    expect { EnvFileRewrite.call(file.reload, text: text) }.to raise_error(EnvFileRewrite::Invalid, "Resolve the conflicts before you publish.")
    get review_s3_file_path(file)
    expect(response).to redirect_to(s3_file_path(file))
    expect(flash[:alert]).to eq("Resolve the conflicts before you publish.")
    previous_requests = client.api_requests.size
    post publish_s3_file_path(file)
    expect(flash[:alert]).to eq("Resolve the conflicts before you publish.")
    expect(client.api_requests.size).to eq(previous_requests)
    edit("resolved-one")
    get s3_file_path(file)
    expect(conflict_box.css(".Box-row").size).to eq(1)
    choose
    get review_s3_file_path(file)
    expect(response).to have_http_status(:ok)
    post publish_s3_file_path(file)
    expect(put_requests.last[:params]).to include(body: "FIRST=resolved-one\nSAME=remote-first\nOTHER=untouched\n", if_match: '"refreshed"')
    expect(PendingEdit.count + PendingChoice.count).to eq(0)
  end

  it "fetches only the object after a failed conditional write and displays conflicts" do
    edit
    choose
    client.stub_responses(:put_object, "PreconditionFailed")
    client.stub_responses(:get_object, [ { body: text, etag: file.etag },
      { body: text.sub("base-one", "remote-one").sub("first", "remote-first"), etag: '"remote"' } ])
    post publish_s3_file_path(file)
    expect(response).to redirect_to(s3_file_path(file))
    expect(flash[:alert]).to eq("The file changed in S3. Check your changes.")
    expect(file.reload.etag).to eq('"remote"')
    expect(PendingEdit.count).to eq(1)
    expect(PendingChoice.count).to eq(1)
    expect(client.api_requests.map { |request| request[:operation_name] }).to eq(%i[get_object put_object get_object])
    expect(client.api_requests.last[:params]).to include(bucket: bucket, key: file.key)
    follow_redirect!
    expect(conflict_box.css(".Box-row").size).to eq(2)
  end

  it "deletes a missing snapshot with no pending changes" do
    client.stub_responses(:list_objects_v2, contents: [])
    post refresh_s3_path
    expect(EnvFile.exists?(file.id)).to be(false)
  end

  [ :edit, :choice, :both ].each do |changes|
    it "keeps a deleted file with #{changes} and refuses all mutations until discard" do
      edit unless changes == :choice
      choose unless changes == :edit
      counts = [ PendingEdit.count, PendingChoice.count ]
      client.stub_responses(:list_objects_v2, contents: [])
      post refresh_s3_path
      expect(file.reload).to be_deleted_in_s3
      expect([ PendingEdit.count, PendingChoice.count ]).to eq(counts)
      get s3_path
      expect(document.at_css("a.Box").text).to include("Deleted in S3")
      get s3_file_path(file)
      expect(document.text).to include("This file is no longer in S3. Your changes cannot be published.")
      expect(document.css("a").map(&:text)).not_to include("Edit", "Resolve", "Change", "Review & publish")
      expect(document.at_css("button[disabled]").text).to eq("Review & publish")
      expect(row("FIRST").text).to include(changes == :choice ? "base-one" : "local-one")
      previous_requests = client.api_requests.size
      [
        [ :get, edit_s3_variable_path(file, name: "FIRST"), {} ],
        [ :post, edit_s3_variable_path(file), { name: "FIRST", value: "rejected", etag: file.etag } ],
        [ :delete, edit_s3_variable_path(file), { name: "FIRST" } ],
        [ :get, s3_variable_choice_path(file, name: "SAME"), {} ],
        [ :post, s3_variable_choice_path(file), { name: "SAME", line_number: 2, line_count: 2 } ],
        [ :delete, s3_variable_choice_path(file), { name: "SAME" } ],
        [ :get, review_s3_file_path(file), {} ],
        [ :post, publish_s3_file_path(file), {} ]
      ].each do |method, path, params|
        public_send(method, path, params: params)
        expect(response).to redirect_to(s3_file_path(file))
        expect(response.headers["Cache-Control"]).to eq("no-store")
        expect(flash[:alert]).to eq("This file is no longer in S3.")
        expect([ PendingEdit.count, PendingChoice.count ]).to eq(counts)
      end
      expect(client.api_requests.size).to eq(previous_requests)
      post discard_s3_changes_path(file)
      expect(response).to redirect_to(s3_path)
      expect(EnvFile.exists?(file.id)).to be(false)
      expect(PendingEdit.count + PendingChoice.count).to eq(0)
    end
  end

  it "clears the deleted record on a later listing and applies conflicts" do
    edit
    choose
    client.stub_responses(:list_objects_v2, contents: [])
    post refresh_s3_path
    refresh_to(text.sub("base-one", "remote-one").sub("first", "remote-first"))
    expect(file.reload).not_to be_deleted_in_s3
    expect(conflict_box.css(".Box-row").size).to eq(2)
    get s3_path
    expect(document.at_css("a.Box").text).not_to include("Deleted in S3")
  end

  [ :put_object, :get_object, :conditional_refresh ].each do |operation|
    it "records a missing object during #{operation} at publish" do
      edit
      if operation == :conditional_refresh
        client.stub_responses(:put_object, "PreconditionFailed")
        client.stub_responses(:get_object, [ { body: text, etag: file.etag }, "NoSuchKey" ])
      else
        client.stub_responses(operation, operation == :get_object ? "NotFound" : "NoSuchKey")
      end
      post publish_s3_file_path(file)
      expect(response).to redirect_to(s3_file_path(file))
      expect(flash[:alert]).to eq("This file is no longer in S3.")
      expect(file.reload).to be_deleted_in_s3
      expect(PendingEdit.first!.value).to eq("local-one")
      expect(put_requests).to be_empty if operation == :get_object
      request_count = client.api_requests.size
      post publish_s3_file_path(file)
      expect(client.api_requests.size).to eq(request_count)
    end
  end

  it "discards every pending change while conflicts are open" do
    edit
    choose
    refresh_to(text.sub("base-one", "remote-one").sub("first", "remote-first"))
    post discard_s3_changes_path(file)
    expect(response).to redirect_to(s3_file_path(file))
    expect(PendingEdit.count + PendingChoice.count).to eq(0)
    expect(snapshot_entries(file).map(&:value)).to include("remote-one")
  end

  it "encrypts secret bases and keeps them out of model inspection" do
    %w[FIRST SAME].each { |name| EnvFileValueTypes.save(file, name: name, value_type: "secret") }
    edit
    choose
    expect(PendingEdit.first!.base_value).to eq("base-one")
    expect(PendingChoice.first!.base_values).to eq(%w[first last])
    { PendingEdit => "base_value", PendingChoice => "base_values" }.each do |model, column|
      raw = raw_rows(model.table_name).first.fetch(column)
      expect(JSON.parse(raw)).to have_key("p")
      expect(raw).not_to include("base-one", "first", "last")
      expect(model.first!.inspect).not_to include("base-one", '"first"', '"last"')
    end
  end
end
