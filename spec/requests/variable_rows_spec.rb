require "rails_helper"

RSpec.describe "S3 variable row storage", type: :request do
  let(:bucket) { "invented-bucket" }
  let(:client) { Aws::S3::Client.new(stub_responses: true, region: "us-east-1") }
  let(:text) { "# invented-comment\nSECRET_KEY=invented-first\nSECRET_KEY=invented-last\nPLAIN=invented-plain\nUNDECIDED=invented-undecided\nBARE_INVENTED\n" }
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

  def mark(name, type)
    post s3_value_types_path(file), params: { name: name, value_type: type }
    expect(response).to redirect_to(s3_file_path(file))
  end

  def edit(name, value)
    post edit_s3_variable_path(file), params: { name: name, value: value, etag: file.reload.etag }
    expect(response).to redirect_to(s3_file_path(file))
  end

  def choose
    post s3_variable_choice_path(file), params: { name: "SECRET_KEY", line_number: 2, line_count: 2 }
    expect(response).to redirect_to(s3_file_path(file))
  end

  def stored_name(table, name)
    raw_rows(table).select { |row| row["name"] == name }
  end

  def all_storage
    connection = ActiveRecord::Base.connection
    connection.tables.flat_map { |table| raw_rows(table) }.to_s
  end

  def refresh_to(text)
    client.stub_responses(:list_objects_v2, contents: [ { key: file.key, size: text.bytesize, etag: '"listed"' } ])
    client.stub_responses(:get_object, body: text, etag: '"remote"')
    post refresh_s3_path
  end

  def puts_to_s3
    client.api_requests.select { |request| request[:operation_name] == :put_object }
  end

  it "stores each assignment, encrypts only secret values and never stores object text" do
    mark("PLAIN", "plain")
    mark("SECRET_KEY", "secret")
    rows = raw_rows("env_file_variables")
    expect(rows.map { |row| [ row["position"], row["line_number"], row["name"] ] }).to eq([
      [ 0, 2, "SECRET_KEY" ], [ 1, 3, "SECRET_KEY" ], [ 2, 4, "PLAIN" ], [ 3, 5, "UNDECIDED" ]
    ])
    expect(stored_name("env_file_variables", "SECRET_KEY").map { |row| row["value_type"] }).to eq(%w[secret secret])
    expect(stored_name("env_file_variables", "PLAIN").sole["value"]).to eq("invented-plain")
    expect(stored_name("env_file_variables", "UNDECIDED").sole.values_at("value", "value_type")).to eq([ "invented-undecided", nil ])
    expect(all_storage).not_to include(text, "invented-first", "invented-last", "invented-comment", "BARE_INVENTED")
    get s3_file_path(file)
    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include("invented-first", "invented-last")
  end

  it "stores edit values and bases and choice bases by type and converts them at once in both directions" do
    mark("PLAIN", "plain")
    choose
    edit("SECRET_KEY", "invented-local-secret")
    edit("PLAIN", "invented-local-plain")
    edit("UNDECIDED", "invented-local-undecided")
    mark("SECRET_KEY", "secret")
    expect(all_storage).not_to include("invented-first", "invented-last", "invented-local-secret")
    %w[PLAIN UNDECIDED].each do |name|
      row = stored_name("pending_edits", name).sole
      suffix = name.downcase
      expect(row.values_at("value", "base_value")).to eq([ "invented-local-#{suffix}", "invented-#{suffix}" ])
    end
    expect(file.pending_choices.reload.sole.base_values).to eq(%w[invented-first invented-last])
    expect(file.pending_edits.reload.find_by!(name: "SECRET_KEY").value).to eq("invented-local-secret")
    mark("SECRET_KEY", "plain")
    expect(stored_name("env_file_variables", "SECRET_KEY").map { |row| row["value"] }).to eq(%w[invented-first invented-last])
    expect(stored_name("pending_edits", "SECRET_KEY").sole.values_at("value", "base_value")).to eq(%w[invented-local-secret invented-first])
    expect(JSON.parse(stored_name("pending_choices", "SECRET_KEY").sole["base_values"])).to eq(%w[invented-first invented-last])
    mark("SECRET_KEY", "secret")
    expect(all_storage).not_to include("invented-first", "invented-last", "invented-local-secret")
  end

  %w[plain undecided].each do |type|
    it "stores repeated #{type} choice bases as written" do
      mark("SECRET_KEY", "plain") if type == "plain"
      choose
      expect(JSON.parse(raw_rows("pending_choices").sole["base_values"])).to eq(%w[invented-first invented-last])
    end
  end

  [ "A B=invalid", "KEY=\xFF".b, "KEY=" + "x" * EnvFileContents::MAX_BYTES ].each do |invalid|
    it "keeps rows, types and changes through an unreadable object of #{invalid.bytesize} bytes" do
      mark("SECRET_KEY", "secret")
      choose
      edit("SECRET_KEY", "invented-local-secret")
      previous = %w[env_file_variables pending_edits pending_choices].to_h { |table| [ table, raw_rows(table) ] }
      request_count = client.api_requests.count { |request| request[:operation_name] == :get_object }
      refresh_to(invalid)
      previous.each { |table, rows| expect(raw_rows(table)).to eq(rows) }
      if invalid.bytesize > EnvFileContents::MAX_BYTES
        expect(client.api_requests.count { |request| request[:operation_name] == :get_object }).to eq(request_count)
      end
      get s3_file_path(file)
      expect(response).to have_http_status(:ok)
      page = Nokogiri::HTML5(response.body)
      expect(page.at_css(".flash-error")).not_to be_nil
      expect(page.css("section")).to be_empty
    end
  end

  it "forgets a departed name's type including pending storage, and treats its return as undecided" do
    mark("SECRET_KEY", "secret")
    choose
    edit("SECRET_KEY", "invented-local-secret")
    refresh_to("PLAIN=invented-plain\n")
    expect(file.variables.reload.pluck(:name)).to eq([ "PLAIN" ])
    expect(stored_name("pending_edits", "SECRET_KEY").sole.values_at("value_type", "value", "base_value"))
      .to eq([ nil, "invented-local-secret", "invented-first" ])
    expect(JSON.parse(raw_rows("pending_choices").sole["base_values"])).to eq(%w[invented-first invented-last])
    refresh_to(text)
    expect(file.variables.reload.where(name: "SECRET_KEY").pluck(:value_type)).to eq([ nil, nil ])
    get s3_file_path(file)
    expect(response.body).to include("SECRET_KEY looks like a secret.")
  end

  [ :review, :publish ].each do |action|
    [ true, false ].each do |same_etag|
      it "refreshes and shows conflicts on #{action} when entries differ with equal ETag #{same_etag}" do
        edit("PLAIN", "invented-local")
        client.stub_responses(:get_object, body: text.sub("invented-plain", "invented-remote"),
          etag: same_etag ? file.etag : '"remote"')
        action == :review ? get(review_s3_file_path(file)) : post(publish_s3_file_path(file))
        expect(response).to redirect_to(s3_file_path(file))
        expect(flash[:alert]).to eq("The file changed in S3. Check your changes.")
        expect(file.variables.reload.find_by!(name: "PLAIN").value).to eq("invented-remote")
        expect(puts_to_s3).to be_empty
        follow_redirect!
        expect(response.body).to include("PLAIN changed in S3 after you edited it.")
      end
    end

    it "refreshes on #{action} when only the ETag differs" do
      edit("PLAIN", "invented-local")
      client.stub_responses(:get_object, body: text, etag: '"different"')
      action == :review ? get(review_s3_file_path(file)) : post(publish_s3_file_path(file))
      expect(flash[:alert]).to eq("The file changed in S3. Check your changes.")
      expect(file.reload.etag).to eq('"different"')
      expect(puts_to_s3).to be_empty
    end

    it "records an object gone during #{action} and keeps local changes" do
      edit("PLAIN", "invented-local")
      client.stub_responses(:get_object, "NoSuchKey")
      action == :review ? get(review_s3_file_path(file)) : post(publish_s3_file_path(file))
      expect(flash[:alert]).to eq("This file is no longer in S3.")
      expect(file.reload).to be_deleted_in_s3
      expect(file.pending_edits.sole.value).to eq("invented-local")
      expect(puts_to_s3).to be_empty
    end
  end

  it "shows the refresh error on review when S3 cannot be reached" do
    edit("PLAIN", "invented-local")
    client.stub_responses(:get_object, Seahorse::Client::NetworkingError.new(SocketError.new("invented-endpoint")))
    get review_s3_file_path(file)
    expect(response).to redirect_to(s3_path)
    expect(flash[:alert]).to eq("S3 cannot be reached.")
    expect(file.pending_edits.sole.value).to eq("invented-local")
    expect(puts_to_s3).to be_empty
  end

  it "reviews and publishes the fetched bytes with comments, blank lines, CRLF and a BOM intact" do
    original = "\uFEFF  SECRET_KEY=invented-first\r\n# invented-comment\r\n\r\nSECRET_KEY=invented-last\r\nBARE_INVENTED\nTAIL=kept".b
    update_env_file(file, content: original)
    mark("SECRET_KEY", "secret")
    edit("SECRET_KEY", "invented-local")
    post reveal_s3_review_path(file), params: { name: "SECRET_KEY" }
    expect(response).to have_http_status(:ok)
    page = Nokogiri::HTML5(response.body)
    expect(page.at_css(".diff-deletion .diff-text").text).to eq("SECRET_KEY=invented-last")
    expect(page.at_css(".diff-addition .diff-text").text).to eq("SECRET_KEY=invented-local")
    expect(page.css(".diff-context .diff-text").map(&:text)).to include("# invented-comment", "", "BARE_INVENTED", "TAIL=kept")
    post publish_s3_file_path(file)
    expect(puts_to_s3.sole[:params][:body].b).to eq(original.sub("invented-last", "invented-local"))
    expect(file.variables.reload.where(name: "SECRET_KEY").pluck(:value_type)).to eq(%w[secret secret])
    expect(all_storage).not_to include("invented-comment", "BARE_INVENTED", "invented-first", "invented-local")
  end

  it "keeps values out of every URL and log through editing, choices, type changes and refresh" do
    output = StringIO.new
    logger = ActiveSupport::Logger.new(output)
    previous = ActiveRecord::Base.logger
    ActiveRecord::Base.logger = logger
    allow(Rails).to receive(:logger).and_return(logger)
    choose
    edit("SECRET_KEY", "invented-local")
    mark("SECRET_KEY", "secret")
    mark("SECRET_KEY", "plain")
    refresh_to(text)
    get review_s3_file_path(file)
    expect(response).to have_http_status(:ok)
    page = Nokogiri::HTML5(response.body)
    urls = page.css("[href], [action]").flat_map { |node| [ node["href"], node["action"] ].compact }.join
    expect(urls).not_to include("invented-first", "invented-last", "invented-local", "invented-plain", "invented-undecided")
    expect(output.string).not_to include("invented-first", "invented-last", "invented-local", "invented-plain", "invented-undecided")
  ensure
    ActiveRecord::Base.logger = previous
  end

  it "needs no encryption key for plain or undecided rows, edits, choices or publication" do
    config = ActiveRecord::Encryption.config
    previous = config.primary_key
    config.primary_key = nil
    choose
    edit("SECRET_KEY", "invented-local")
    mark("PLAIN", "plain")
    get review_s3_file_path(file)
    expect(response).to have_http_status(:ok)
    post publish_s3_file_path(file)
    expect(flash[:notice]).to eq("Published the env file to S3.")
    expect(puts_to_s3.sole[:params][:body]).to include("SECRET_KEY=invented-local")
  ensure
    config.primary_key = previous
  end

  it "rolls back a type change if a secret cannot be written without the key" do
    config = ActiveRecord::Encryption.config
    previous = config.primary_key
    config.primary_key = nil
    post s3_value_types_path(file), params: { name: "SECRET_KEY", value_type: "secret" }
    expect(response).to redirect_to(s3_path)
    expect(flash[:alert]).to include("ENVS_ENCRYPTION_KEY")
    expect(file.variables.reload.pluck(:value_type)).to all(be_nil)
  ensure
    config.primary_key = previous
  end

  it "asks for the key when a page reads a secret" do
    mark("SECRET_KEY", "secret")
    config = ActiveRecord::Encryption.config
    previous = config.primary_key
    config.primary_key = nil
    get s3_file_path(file)
    expect(response).to redirect_to(s3_path)
    expect(flash[:alert]).to include("ENVS_ENCRYPTION_KEY")
    get s3_path
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Snapshots unavailable")
    expect(response.body).not_to include("invented-first", "invented-last")
  ensure
    config.primary_key = previous
  end
end
