require "rails_helper"

RSpec.describe "S3 variable types", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:bucket) { "invented-bucket" }
  let(:text) { "POSTGRES_PASSWORD=invented-first\nPOSTGRES_PASSWORD=invented-last\napi-key=invented-key\nTZ=UTC\n" }
  let!(:file) { create_env_file(bucket: bucket, key: "invented.env", content: text, etag: '"old"', fetched_at: Time.current) }
  let(:client) { Aws::S3::Client.new(stub_responses: true, region: "us-east-1") }

  around do |example|
    previous = ENV["ENVS_S3_BUCKET"]
    ENV["ENVS_S3_BUCKET"] = bucket
    travel_to(Time.utc(2026, 11, 14, 12)) { example.run }
  ensure
    previous ? ENV["ENVS_S3_BUCKET"] = previous : ENV.delete("ENVS_S3_BUCKET")
  end

  before do
    allow(EnvFileRefresh).to receive(:client).and_return(client)
    allow(EnvFilePublish).to receive(:client).and_return(client)
  end

  def document
    Nokogiri::HTML5(response.body)
  end

  def suggestions
    document.css('[aria-label="Suggestions"] .Box-row')
  end

  def rows
    document.css('[aria-label="Variables"] .Box-row')
  end

  def mark(name = "POSTGRES_PASSWORD", value_type: "secret", dismiss: false)
    post s3_value_types_path(file), params: { name: name, value_type: value_type, dismiss: dismiss ? "1" : "0" }
    expect(response).to redirect_to(s3_file_path(file))
    expect(response.headers["Cache-Control"]).to eq("no-store")
    follow_redirect!
  end

  def refresh(text)
    client.stub_responses(:list_objects_v2, contents: [ { key: file.key, size: text.bytesize } ])
    client.stub_responses(:get_object, body: text, etag: '"refreshed"')
    post refresh_s3_path
  end

  it "suggests each undecided qualifying name once, without deciding or inspecting values" do
    update_env_file(file, content: text + "Db.Token=x\nSECRET=y\nKEYBOARD=secret\nPASSPORT=password\nMONKEY=token\n")
    get s3_file_path(file)
    expect(suggestions.map { |row| row.at_css("p").text }).to eq([
      "POSTGRES_PASSWORD looks like a secret.", "api-key looks like a secret.",
      "Db.Token looks like a secret.", "SECRET looks like a secret."
    ])
    expect(suggestions.map { |row| row.css("button").map(&:text) }).to all(eq([ "Mark as secret", "Dismiss" ]))
    expect(document.css("section").map { |section| section["aria-label"] }).to eq([ "Suggestions", "Variables" ])
    expect(file.variables.where.not(value_type: nil).count).to eq(0)
    update_env_file(file, content: "KEYBOARD=secret\nPASSPORT=password\nMONKEY=token\nTZ=PASSWORD\n")
    get s3_file_path(file)
    expect(document.at_css('[aria-label="Suggestions"]')).to be_nil
  end

  it "marks a repeated name immediately, labels every line and removes its suggestion" do
    mark
    expect(document.text).to include("Marked POSTGRES_PASSWORD as secret.")
    row = file.variables.where.not(value_type: nil).first!
    expect(row.attributes.slice("env_file_id", "name", "value_type")).to eq(
      "env_file_id" => file.id, "name" => "POSTGRES_PASSWORD", "value_type" => "secret")
    expect(rows.first(2).map { |entry| entry.css(".Label").map(&:text) }).to eq([ [ "Overridden", "Secret" ], [ "Secret" ] ])
    expect(rows.map { |entry| entry.at_css(".variable-value").text }).to eq([ "invented-first", "invented-last", "invented-key", "UTC" ])
    expect(suggestions.map(&:text).join).not_to include("POSTGRES_PASSWORD")
    expect(file.reload).not_to be_pending_changes
    get s3_path
    expect(document.at_css("a.Box").text).not_to include("Modified", "Secret")
  end

  it "dismisses a suggestion as an explicit plain type" do
    mark(value_type: "plain", dismiss: true)
    expect(file.variables.where.not(value_type: nil).first!).to be_plain
    expect(document.text).to include("Dismissed the suggestion for POSTGRES_PASSWORD.")
    expect(rows.css(".Label").map(&:text)).not_to include("Secret")
    expect(suggestions.map(&:text).join).not_to include("POSTGRES_PASSWORD")
    mark("api-key", value_type: "plain", dismiss: true)
    expect(document.at_css('[aria-label="Suggestions"]')).to be_nil
  end

  it "shows the default type on edit and lets the user switch both ways" do
    get edit_s3_variable_path(file, name: "TZ")
    expect(document.text).to include("Type: plain")
    expect(document.css("button").map(&:text)).to include("Mark as secret")
    expect(document.css("button").map(&:text)).not_to include("Mark as plain")
    mark("TZ")
    get edit_s3_variable_path(file, name: "TZ")
    expect(document.text).to include("Type: secret")
    expect(document.css("button").map(&:text)).to include("Mark as plain")
    expect(document.css("button").map(&:text)).not_to include("Mark as secret")
    mark("TZ", value_type: "plain")
    expect(document.text).to include("Marked TZ as plain.")
    expect(file.variables.where.not(value_type: nil).first!).to be_plain
  end

  [ 80, 6_000 ].each do |length|
    it "keeps a #{length}-character name intact and bounds all three type messages" do
      name = "PASSWORD_" + "x" * (length - 9)
      update_env_file(file, content: "#{name}=invented-value\n")
      get s3_file_path(file)
      expect(suggestions.sole.at_css("p").text).to eq("#{name} looks like a secret.")
      expect(rows.sole.at_css(".text-bold").text).to eq(name)
      get edit_s3_variable_path(file, name: name)
      expect(document.at_css('label[for="value"]').text).to eq(name)
      expect(document.at_css('input[name="name"]')["value"]).to eq(name)

      shown_name = length > 80 ? "#{name.first(80)}…" : name
      [
        [ "secret", false, "Marked #{shown_name} as secret." ],
        [ "plain", true, "Dismissed the suggestion for #{shown_name}." ],
        [ "plain", false, "Marked #{shown_name} as plain." ]
      ].each do |value_type, dismiss, message|
        mark(name, value_type: value_type, dismiss: dismiss)
        expect(file.variables.where.not(value_type: nil).first!.name).to eq(name)
        expect(file.variables.where.not(value_type: nil).first!.value_type).to eq(value_type)
        expect(document.at_css(".flash-success").text).to eq(message)
        expect(rows.sole.at_css(".text-bold").text).to eq(name)
      end
    end
  end

  [ "plain", "secret" ].each do |value_type|
    [ :invalid_value, :stale_snapshot ].each do |refusal|
      it "keeps the #{value_type} type and its button after refusing a value for #{refusal}" do
        mark(value_type: value_type)
        params = { name: "POSTGRES_PASSWORD", value: "invented-edit", etag: file.etag }
        refusal == :invalid_value ? params[:value] = "invalid\nvalue" : params[:etag] = '"stale"'
        post edit_s3_variable_path(file), params: params
        expect(response).to have_http_status(:unprocessable_content)
        expect(document.at_css(".flash-error")).not_to be_nil
        expect(document.text).to include("Type: #{value_type}")
        form = document.css("form").find { |node| node["action"] == s3_value_types_path(file) }
        expect(form.at_css("button").text).to eq(value_type == "secret" ? "Mark as plain" : "Mark as secret")
        expect(form.at_css('input[name="value_type"]')["value"]).to eq(value_type == "secret" ? "plain" : "secret")
        expect(file.variables.where.not(value_type: nil).first!.value_type).to eq(value_type)
        expect(PendingEdit.count).to eq(0)
      end
    end
  end

  it "refuses an unknown type, a missing name, an invalid snapshot and a deleted file without changing stored types" do
    mark
    original = file.variables.where.not(value_type: nil).first!.attributes
    [
      [ { name: "POSTGRES_PASSWORD", value_type: "unknown" }, "Choose secret or plain." ],
      [ { name: "MISSING", value_type: "plain" }, "The variable no longer exists." ]
    ].each do |input, message|
      post s3_value_types_path(file), params: input
      expect(response).to redirect_to(s3_file_path(file))
      follow_redirect!
      expect(document.at_css(".flash-error").text).to include(message)
      expect(file.variables.where.not(value_type: nil).first!.attributes).to eq(original)
    end
    update_env_file(file, content: "INVALID")
    mark(value_type: "plain")
    expect(document.at_css(".flash-error").text).not_to be_empty
    expect(file.variables.where.not(value_type: nil).first!.attributes).to eq(original)
    update_env_file(file, content: text, deleted_in_s3: true)
    mark(value_type: "plain")
    expect(document.at_css(".flash-error").text).to include("no longer in S3")
    expect(file.variables.where(name: "POSTGRES_PASSWORD").pluck(:value_type)).to eq(%w[secret secret])
  end

  it "keeps the review, choices and edits unchanged and retains types after discard and publish" do
    post s3_variable_choice_path(file), params: { name: "POSTGRES_PASSWORD", line_number: 1, line_count: 2 }
    post edit_s3_variable_path(file), params: { name: "POSTGRES_PASSWORD", value: "invented-edit", etag: file.etag }
    get review_s3_file_path(file)
    review = document.at_css("main .Box").to_html
    edits = file.pending_edits.reload.map { |edit| [ edit.name, edit.value, edit.base_value ] }
    choices = file.pending_choices.reload.map { |choice| [ choice.name, choice.base_values ] }
    get s3_file_path(file)
    modified_count = document.css(".Label").count { |label| label.text == "Modified" }
    mark
    expect(document.css(".Label").count { |label| label.text == "Modified" }).to eq(modified_count)
    expect(file.pending_edits.reload.map { |edit| [ edit.name, edit.value, edit.base_value ] }).to eq(edits)
    expect(file.pending_choices.reload.map { |choice| [ choice.name, choice.base_values ] }).to eq(choices)
    get review_s3_file_path(file)
    expect(document.at_css("main .Box").to_html).to eq(review)
    post discard_s3_changes_path(file)
    expect(file.reload).not_to be_pending_changes
    expect(file.variables.where.not(value_type: nil).first!).to be_secret
    post s3_variable_choice_path(file), params: { name: "POSTGRES_PASSWORD", line_number: 1, line_count: 2 }
    post edit_s3_variable_path(file), params: { name: "POSTGRES_PASSWORD", value: "invented-published", etag: file.etag }
    client.stub_responses(:head_object, content_type: "text/plain")
    client.stub_responses(:put_object, etag: '"published"')
    post publish_s3_file_path(file)
    expect(response).to redirect_to(s3_file_path(file))
    expect(snapshot_entries(file).map(&:value)).to include("invented-published")
    expect(file).not_to be_pending_changes
    expect(file.variables.where.not(value_type: nil).first!).to be_secret
  end

it "keeps a type for a name that stays and forgets names that leave" do
  mark
  refresh(text.sub("invented-last", "invented-refreshed") + "POSTGRES_PASSWORD=invented-added\n")
  expect(file.variables.where(name: "POSTGRES_PASSWORD").pluck(:value_type)).to eq(%w[secret secret secret])
  refresh("TZ=UTC\n")
  expect(file.variables.where(name: "POSTGRES_PASSWORD")).to be_empty
  refresh(text)
  get s3_file_path(file)
  expect(rows.first(2).map(&:text).join).not_to include("Secret")
  expect(suggestions.map(&:text).join).to include("POSTGRES_PASSWORD")
  old_id = file.id
  client.stub_responses(:list_objects_v2, contents: [])
  post refresh_s3_path
  expect(EnvFile.exists?(old_id)).to be(false)
  refresh(text)
  restored = EnvFile.find_by!(bucket: bucket, key: file.key)
  expect(restored.id).not_to eq(old_id)
  expect(restored.variables.pluck(:value_type)).to all(be_nil)
end

  it "scopes the type to both bucket and key" do
    mark
    other = create_env_file(bucket: bucket, key: "other.env", content: text, fetched_at: Time.current)
    get s3_file_path(other)
    expect(suggestions.map(&:text).join).to include("POSTGRES_PASSWORD")
    expect(rows.css(".Label").map(&:text)).not_to include("Secret")
    ENV["ENVS_S3_BUCKET"] = "other-invented-bucket"
    other.update!(bucket: ENV["ENVS_S3_BUCKET"], key: file.key)
    get s3_file_path(other)
    expect(suggestions.map(&:text).join).to include("POSTGRES_PASSWORD")
    expect(rows.css(".Label").map(&:text)).not_to include("Secret")
  end

  it "shows no suggestions for invalid, oversized or deleted S3 files" do
    [ { content: "INVALID" }, { too_large: true }, { deleted_in_s3: true } ].each do |attributes|
      update_env_file(file, **{ content: text, too_large: false, deleted_in_s3: false }.merge(attributes))
      get s3_file_path(file)
      expect(document.at_css('[aria-label="Suggestions"]')).to be_nil
      expect(response.headers["Cache-Control"]).to eq("no-store")
    end
  end

  it "leaves uploads unchanged even for a name marked secret in S3" do
    mark
    upload = Rack::Test::UploadedFile.new(StringIO.new(text), "text/plain", true, original_filename: "invented.env")
    post files_path, params: { file: upload }
    follow_redirect!
    expect(response).to have_http_status(:ok)
    expect(document.at_css('[aria-label="Suggestions"]')).to be_nil
    expect(rows.css(".Label").map(&:text)).not_to include("Secret")
    expect(document.css("button")).to be_empty
    expect(response.headers["Cache-Control"]).to eq("no-store")
  end

  it "uses normal POST forms and never puts a value in a URL or log" do
    output = StringIO.new
    logger = ActiveSupport::Logger.new(output)
    original = ActiveRecord::Base.logger
    ActiveRecord::Base.logger = logger
    allow(Rails).to receive(:logger).and_return(logger)
    get s3_file_path(file)
    form = suggestions.first.at_css("form")
    expect(form["method"]).to eq("post")
    expect(form["action"]).to eq(s3_value_types_path(file))
    expect(form.at_css('input[name="name"]')["value"]).to eq("POSTGRES_PASSWORD")
    expect(form.at_css('input[name="value_type"]')["value"]).to eq("secret")
    post form["action"], params: { name: "POSTGRES_PASSWORD", value_type: "secret" }
    expect(response.location).not_to include("invented-first", "invented-last", "invented-key")
    follow_redirect!
    urls = document.css("[href], [action]").flat_map { |node| [ node["href"], node["action"] ].compact }
    expect(urls.join).not_to include("invented-first", "invented-last", "invented-key")
    expect(output.string).not_to include("invented-first", "invented-last", "invented-key")
  ensure
    ActiveRecord::Base.logger = original
  end
end
