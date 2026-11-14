require "rails_helper"

RSpec.describe "Secret visibility", type: :request do
  let(:bucket) { "invented-mask-bucket" }
  let(:client) { Aws::S3::Client.new(stub_responses: true, region: "us-east-1") }
  let(:text) { "\uFEFF  PRIVATE=invented-first\nPRIVATE= invented-stored \t\nOTHER=invented-other\nPLAIN=invented-plain\nPLAIN=invented-plain-last\nUNDECIDED=invented-null\nUNDECIDED=invented-null-last\n" }
  let!(:file) { create_env_file(bucket: bucket, key: "invented.env", content: text, etag: '"original"', fetched_at: Time.utc(2026, 11, 14, 12)) }
  let(:mask) { "••••••••" }

  around do |example|
    previous = ENV["ENVS_S3_BUCKET"]
    ENV["ENVS_S3_BUCKET"] = bucket
    example.run
  ensure
    previous ? ENV["ENVS_S3_BUCKET"] = previous : ENV.delete("ENVS_S3_BUCKET")
  end

  before do
    allow(EnvFileRefresh).to receive(:client).and_return(client)
    %w[PRIVATE OTHER].each { |name| EnvFileValueTypes.save(file, name: name, value_type: "secret") }
    EnvFileValueTypes.save(file, name: "PLAIN", value_type: "plain")
    save_value("PRIVATE", "invented-pending")
  end

  def document
    Nokogiri::HTML5(response.body)
  end

  def save_value(name, value, etag: file.etag)
    post edit_s3_variable_path(file), params: { name: name, value: value, etag: etag }
  end

  def page_path(page, name = "PRIVATE")
    case page
    when :file then s3_file_path(file)
    when :edit then edit_s3_variable_path(file, name: name)
    when :choice then s3_variable_choice_path(file, name: name)
    when :review then review_s3_file_path(file)
    end
  end

  def reveal_path(page)
    case page
    when :file then reveal_s3_file_path(file)
    when :edit then reveal_s3_edit_path(file)
    when :choice then reveal_s3_choice_path(file)
    when :review then reveal_s3_review_path(file)
    end
  end

  def expect_hidden
    expect(response.body).not_to include("invented-first", "invented-stored", "invented-pending", "invented-other")
  end

  def expect_empty_field
    expect(document.at_css('input[name="value"]')["value"]).to eq("")
  end

  %i[file edit choice review].each do |page|
    it "masks the #{page} response and reveals only the requested name for one request" do
      get page_path(page)
      expect(response).to have_http_status(:ok)
      expect_hidden
      expect(document.text).to include(mask) unless page == :edit
      expect(document.css('button[aria-label="Show PRIVATE"]').size).to eq(page == :file ? 2 : 1)
      expect_empty_field if page == :edit
      post reveal_path(page), params: { name: "PRIVATE" }
      expect(response).to have_http_status(:ok)
      expect(response.headers["Cache-Control"]).to eq("no-store")
      expected = case page
      when :choice then %w[invented-first invented-stored]
      when :edit then %w[invented-stored invented-pending]
      when :file then %w[invented-first invented-pending]
      when :review then %w[invented-first invented-stored invented-pending]
      end
      expect(response.body).to include(*expected)
      expect(response.body).not_to include("invented-other")
      expect(document.css("a").map(&:text)).to include("Hide")
      expect_empty_field if page == :edit
      get page_path(page)
      expect_hidden
    end

    [ "PLAIN", "UNDECIDED" ].each do |name|
      it "keeps #{name} visible on #{page}, including after Show" do
        save_value(name, "invented-visible-pending") unless page == :choice
        get page_path(page, name)
        expect(response).to have_http_status(:ok)
        expect(response.body).to include(page == :choice ? (name == "PLAIN" ? "invented-plain-last" : "invented-null-last") : "invented-visible-pending")
        post reveal_path(page), params: { name: name }
        expect(response).to have_http_status(:ok)
        expect(response.headers["Cache-Control"]).to eq("no-store")
        expect_hidden
        expect(response.body).to include(page == :choice ? (name == "PLAIN" ? "invented-plain-last" : "invented-null-last") : "invented-visible-pending")
      end
    end

    it "ignores a missing name on #{page} Show" do
      post reveal_path(page), params: { name: "MISSING" }
      expect(response).to have_http_status(:ok)
      expect(response.headers["Cache-Control"]).to eq("no-store")
      expect(document.css(".flash-error")).to be_empty
      expect_hidden
    end
  end

  it "masks every repeated row, keeps labels and reveals all occurrences" do
    get s3_file_path(file)
    rows = document.css('[aria-label="Variables"] .Box-row').first(2)
    expect(rows.map { |row| row.at_css(".variable-value").text }).to eq([ mask, mask ])
    file.pending_edits.delete_all
    get s3_file_path(file)
    expect(document.css('[aria-label="Variables"] .Box-row')[1].text).to include("Leading or trailing whitespace")
    expect(rows.first.text).to include("Overridden")
    expect(rows.last.text).to include("Modified")
    save_value("PRIVATE", "invented-pending")
    post reveal_s3_file_path(file), params: { name: "PRIVATE" }
    expect(document.css(".variable-value").first(2).map(&:text)).to eq([ "invented-first", "invented-pending" ])
    get s3_variable_choice_path(file, name: "PRIVATE")
    expect(document.css("fieldset label").map { |label| label.text.strip }).to eq([ "Line 1: #{mask}", "Line 2: #{mask}" ])
    post reveal_s3_choice_path(file), params: { name: "PRIVATE" }
    expect(document.css("fieldset label").map { |label| label.text.strip }).to eq([ "Line 1: invented-first", "Line 2:  invented-stored" ])
  end

  it "requires a typed secret value and preserves an existing edit on an empty save" do
    original = file.pending_edits.sole.attributes
    save_value("PRIVATE", "")
    expect(response).to have_http_status(:unprocessable_content)
    expect(document.text).to include("Type a value.")
    expect_empty_field
    expect_hidden
    expect(file.pending_edits.reload.sole.attributes).to eq(original)
    file.pending_edits.delete_all
    save_value("PRIVATE", "")
    expect(file.pending_edits.reload).to be_empty
    save_value("PRIVATE", "invented-typed")
    expect(response).to redirect_to(s3_file_path(file))
    expect(file.pending_edits.reload.sole.value).to eq("invented-typed")
  end

  [ [ "invented-invalid\nvalue", '"original"' ], [ "invented-refused", '"stale"' ] ].each do |value, etag|
    it "empties the field after refusing a save with #{value.inspect} and #{etag}" do
      original = file.pending_edits.sole.attributes
      save_value("PRIVATE", value, etag: etag)
      expect(response).to have_http_status(:unprocessable_content)
      expect_empty_field
      expect_hidden
      expect(response.body).not_to include(value, "invented-invalid", "invented-refused")
      expect(file.pending_edits.reload.sole.attributes).to eq(original)
    end
  end

  it "masks conflict values and reveals the base, current and pending values together" do
    update_env_file(file, content: text.sub("invented-stored", "invented-remote"), etag: '"changed"')
    get edit_s3_variable_path(file, name: "PRIVATE")
    expect_hidden
    expect(response.body).not_to include("invented-remote")
    expect(document.css(".flash-warn .text-mono").map(&:text)).to eq([ mask, mask ])
    post reveal_s3_edit_path(file), params: { name: "PRIVATE" }
    expect(response.body).to include("invented-stored", "invented-remote", "invented-pending")
    expect_empty_field
  end

  it "masks old, new and context lines, preserving the prefix through the first equals sign" do
    get review_s3_file_path(file)
    expect(document.css(".diff-text").map(&:text)).to include("\uFEFF  PRIVATE=#{mask}", "PRIVATE=#{mask}", "OTHER=#{mask}")
    expect(document.at_css(".diff-deletion .diff-text").text).to eq("PRIVATE=#{mask}")
    expect(document.at_css(".diff-addition .diff-text").text).to eq("PRIVATE=#{mask}")
    expect(document.css('button[aria-label="Show PRIVATE"]').size).to eq(1)
    post reveal_s3_review_path(file), params: { name: "PRIVATE" }
    expect(document.css(".diff-text").map(&:text)).to include("\uFEFF  PRIVATE=invented-first", "PRIVATE= invented-stored \t", "PRIVATE=invented-pending", "OTHER=#{mask}")
  end

  it "refreshes a changed object on review Show" do
    client.stub_responses(:get_object, body: text.sub("invented-stored", "invented-remote"), etag: '"changed"')
    post reveal_s3_review_path(file), params: { name: "PRIVATE" }
    expect(response).to redirect_to(s3_file_path(file))
    follow_redirect!
    expect(document.text).to include("The file changed in S3. Check your changes.")
    expect_hidden
    expect(response.body).not_to include("invented-remote")
    expect(file.reload.etag).to eq('"changed"')
  end

  it "records a missing object on review Show and permits Show on its file page" do
    client.stub_responses(:get_object, "NoSuchKey")
    post reveal_s3_review_path(file), params: { name: "PRIVATE" }
    expect(response).to redirect_to(s3_file_path(file))
    follow_redirect!
    expect(document.text).to include("This file is no longer in S3.")
    expect_hidden
    expect(document.css('button[aria-label="Show PRIVATE"]').size).to eq(2)
    post reveal_s3_file_path(file), params: { name: "PRIVATE" }
    expect(response).to have_http_status(:ok)
    expect(response.headers["Cache-Control"]).to eq("no-store")
    expect(response.body).to include("invented-first", "invented-pending")
    expect(response.body).not_to include("invented-other")
    expect(document.css("a").map(&:text)).to include("Hide")
  end

  it "switches visibility immediately when the type changes" do
    post s3_value_types_path(file), params: { name: "PRIVATE", value_type: "plain" }
    follow_redirect!
    expect(response.body).to include("invented-first", "invented-pending")
    post s3_value_types_path(file), params: { name: "PRIVATE", value_type: "secret" }
    follow_redirect!
    expect_hidden
  end

  it "reports the missing encryption key for Show" do
    original = ActiveRecord::Encryption.config.primary_key
    ActiveRecord::Encryption.config.primary_key = nil
    post reveal_s3_file_path(file), params: { name: "PRIVATE" }
    expect(response).to redirect_to(s3_path)
    expect(flash[:alert]).to eq("Set ENVS_ENCRYPTION_KEY to read and save secret values.")
    expect(response.headers["Cache-Control"]).to eq("no-store")
  ensure
    ActiveRecord::Encryption.config.primary_key = original
  end

  it "leaves uploads visible without masks or Show buttons" do
    upload = Rack::Test::UploadedFile.new(StringIO.new(text), "text/plain", true, original_filename: "invented.env")
    post files_path, params: { file: upload }
    follow_redirect!
    expect(response.body).to include("invented-first", "invented-stored", "invented-other")
    expect(document.text).not_to include(mask)
    expect(document.css("button").map(&:text)).not_to include("Show")
  end

  it "keeps values out of URLs and logs during Show on every page" do
    output = StringIO.new
    logger = ActiveSupport::Logger.new(output)
    original = ActiveRecord::Base.logger
    ActiveRecord::Base.logger = logger
    allow(Rails).to receive(:logger).and_return(logger)
    %i[file edit choice review].each do |page|
      post reveal_path(page), params: { name: "PRIVATE" }
      expect(response).to have_http_status(:ok)
      urls = document.css("[href], [action]").flat_map { |node| [ node["href"], node["action"] ].compact }.join
      expect(urls).not_to include("invented-first", "invented-stored", "invented-pending", "invented-other")
    end
    expect(output.string).not_to include("invented-first", "invented-stored", "invented-pending", "invented-other")
  ensure
    ActiveRecord::Base.logger = original
  end
end
