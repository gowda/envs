require "rails_helper"

RSpec.describe "S3 dotenv files", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:bucket) { "invented-envs-bucket" }
  let(:prefix) { "invented/" }
  let(:modified) { Time.utc(2026, 11, 1, 12) }
  let(:client) { Aws::S3::Client.new(stub_responses: true, region: "us-east-1") }
  let(:contents) { { "invented/.env" => "FIRST=invented-value\nSECOND=two\n" } }

  around do |example|
    settings = { "ENVS_S3_BUCKET" => bucket, "ENVS_S3_PREFIX" => prefix }
    previous = ENV.to_h.slice(*settings.keys)
    settings.each { |key, value| ENV[key] = value }
    travel_to(Time.utc(2026, 11, 14, 12)) { example.run }
  ensure
    settings.each_key { |key| previous.key?(key) ? ENV[key] = previous[key] : ENV.delete(key) }
  end

  before do
    allow(EnvFileRefresh).to receive(:client).and_return(client)
    client.stub_responses(:list_objects_v2, contents: [ object("invented/.env") ])
    client.stub_responses(:get_object, ->(context) {
      { body: contents.fetch(context.params[:key]), etag: '"invented-etag"', last_modified: modified }
    })
  end

  def object(key, size: 40)
    { key: key, size: size, etag: '"listed-etag"', last_modified: modified }
  end

  def document
    Nokogiri::HTML5(response.body)
  end

  def refresh
    post refresh_env_files_path
    expect(response).to redirect_to(root_path)
    follow_redirect!
    expect(response).to have_http_status(:ok)
  end

  it "refreshes every page, selects all three name patterns and displays cards and errors" do
    contents.merge!("invented/.env.production" => "MODE=invented-production\n",
      "invented/app.env" => "APP=invented-app\n", "invented/bad.env" => "invalid text")
    client.stub_responses(:list_objects_v2, [
      { contents: [ object("invented/.env"), object("invented/.env.production") ],
        is_truncated: true, next_continuation_token: "invented-next-page" },
      { contents: [ object("invented/app.env"), object("invented/bad.env"),
        object("invented/big.env", size: DotenvContents::MAX_BYTES + 1), object("invented/ignored.txt"),
        object("invented/.env.directory/") ], is_truncated: false }
    ])

    refresh

    expect(document.at_css(".flash-success").text).to eq("Refreshed 5 dotenv files from S3.")
    expect(EnvFile.count).to eq(5)
    listings = client.api_requests.select { |request| request[:operation_name] == :list_objects_v2 }
    expect(listings.map { |request| request[:params] }).to eq([
      { bucket: bucket, prefix: prefix },
      { bucket: bucket, prefix: prefix, continuation_token: "invented-next-page" }
    ])
    downloads = client.api_requests.select { |request| request[:operation_name] == :get_object }
    expect(downloads.map { |request| request[:params][:key] }).to match_array(contents.keys)
    cards = document.css('[aria-label="Dotenv files"] a.Box')
    expect(cards.size).to eq(5)
    expect(cards.map { |card| card.at_css("h2").text }).to include(".env", ".env.production", "app.env")
    expect(cards.first.text).to include("invented/.env", "2 variables", modified.iso8601)
    expect(cards.first["href"]).to eq(env_file_path(EnvFile.find_by!(key: "invented/.env")))
    expect(document.text).to include("Invalid dotenv file", "Too large")
    expect(document.text).not_to include("invented-value", "ignored.txt")
    expect(document.css("script")).to be_empty
    expect(response.headers["Cache-Control"]).to eq("no-store")
    expect(EnvFile.find_by!(key: "invented/big.env").content).to be_nil
    expect(EnvFile.find_by!(key: "invented/.env").attributes.slice("etag", "last_modified", "fetched_at"))
      .to eq("etag" => '"invented-etag"', "last_modified" => modified, "fetched_at" => Time.current)

    get env_file_path(EnvFile.find_by!(key: "invented/bad.env"))
    expect(document.at_css(".flash-error").text).to eq(DotenvContents::INVALID_MESSAGE)
    expect(document.css("section")).to be_empty

    get env_file_path(EnvFile.find_by!(key: "invented/big.env"))
    expect(document.at_css(".flash-error").text).to eq(DotenvContents::TOO_LARGE_MESSAGE)
  end

  it "renders the shared variable list with literal commands, escaped HTML and no caching" do
    contents["invented/.env"] = "FIRST=invented-value\nMULTI=\"line one\n<script>invented</script>\"\nCOMMAND=$(echo invented)\nREFERENCE=$PATH\n"
    refresh
    file = EnvFile.find_by!(bucket: bucket, key: "invented/.env")

    get env_file_path(file)

    expect(response).to have_http_status(:ok)
    expect(document.at_css("h1").text).to eq(".env")
    expect(document.css("section .Box-row").size).to eq(4)
    expect(document.at_css("section pre").text).to eq("line one\n<script>invented</script>")
    expect(document.text).to include("invented-value", "$(echo invented)", "$PATH")
    expect(document.css("script")).to be_empty
    expect(response.headers["Cache-Control"]).to eq("no-store")
    expect(document.css("header a").map { |link| link["href"] }).to eq([ root_path, upload_path ])
    raw = EnvFile.connection.select_value("SELECT content FROM env_files WHERE id = #{file.id.to_i}")
    expect(raw).not_to include("invented-value", "FIRST", "MULTI")
    expect(JSON.parse(raw)).to have_key("p")
    expect(file.content).to eq(contents["invented/.env"])
    expect(file.inspect).not_to include("invented-value")
  end

  it "updates existing snapshots and deletes removed objects only in the configured bucket" do
    refresh
    file = EnvFile.find_by!(bucket: bucket, key: "invented/.env")
    removed = EnvFile.create!(bucket: bucket, key: "invented/removed.env", content: "OLD=invented", fetched_at: Time.current)
    other = EnvFile.create!(bucket: "invented-other-bucket", key: "other.env", content: "OTHER=invented", fetched_at: Time.current)
    contents["invented/.env"] = "UPDATED=invented-new-value\n"
    client.stub_responses(:get_object, body: contents["invented/.env"], etag: '"updated-etag"', last_modified: modified + 1.hour)

    refresh

    expect(file.reload.content).to eq("UPDATED=invented-new-value\n")
    expect(file.etag).to eq('"updated-etag"')
    expect(file.last_modified).to eq(modified + 1.hour)
    expect(EnvFile.exists?(removed.id)).to be(false)
    expect(EnvFile.exists?(other.id)).to be(true)
    expect(EnvFile.where(bucket: bucket).count).to eq(1)
  end

  it "removes all snapshots when the listing is empty" do
    refresh
    client.stub_responses(:list_objects_v2, contents: [])

    refresh

    expect(EnvFile.count).to eq(0)
    expect(document.at_css(".blankslate").text).to include("No snapshots yet")
  end

  it "preserves invalid UTF-8 as an encrypted invalid snapshot" do
    contents["invented/.env"] = "KEY=\xFF".b
    refresh

    get env_file_path(EnvFile.first!)

    expect(document.at_css(".flash-error").text).to include("valid UTF-8")
  end

  it "round-trips a file exactly 1 MB" do
    contents["invented/.env"] = "KEY=" + "a" * (DotenvContents::MAX_BYTES - 4)
    client.stub_responses(:list_objects_v2, contents: [ object("invented/.env", size: DotenvContents::MAX_BYTES) ])

    refresh

    expect(EnvFile.first!.content).to eq(contents["invented/.env"])
    get env_file_path(EnvFile.first!)
    expect(document.at_css("section .col-8").text.bytesize).to eq(DotenvContents::MAX_BYTES - 4)
  end

  it "limits a download if an object grew after listing" do
    contents["invented/.env"] = "KEY=" + "a" * DotenvContents::MAX_BYTES

    refresh

    expect(EnvFile.first!).to be_too_large
    expect(EnvFile.first!.content).to be_nil
    expect(document.text).to include("Too large")
  end

  it "shows the bucket configuration blankslate without making an AWS call" do
    ENV.delete("ENVS_S3_BUCKET")

    get root_path

    expect(response).to have_http_status(:ok)
    expect(document.at_css(".blankslate").text).to include("ENVS_S3_BUCKET", "ENVS_S3_PREFIX", "AWS_REGION", "ENVS_ENCRYPTION_KEY")
    expect(document.css("script")).to be_empty
    refresh
    expect(document.at_css(".flash-error").text).to include("ENVS_S3_BUCKET")
    expect(client.api_requests).to be_empty
  end

  it "shows the empty snapshot blankslate and refresh button" do
    get root_path

    expect(response).to have_http_status(:ok)
    expect(document.at_css(".blankslate").text).to include("No snapshots yet", "Refresh from S3")
    expect(document.at_css("form")["action"]).to eq(refresh_env_files_path)
    expect(client.api_requests).to be_empty
  end

  it "shows a safe AWS error without altering snapshots or exposing the exception" do
    refresh
    file = EnvFile.first!
    client.stub_responses(:list_objects_v2, "AccessDenied")

    refresh

    expect(document.at_css(".flash-error").text).to eq("S3 refresh failed. Check bucket access and try again.")
    expect(EnvFile.first!.attributes).to eq(file.attributes)
  end

  it "rolls back updates and deletions when a download fails" do
    refresh
    file = EnvFile.first!
    contents["invented/.env"] = "CHANGED=invented\n"
    client.stub_responses(:list_objects_v2, contents: [ object("invented/.env"), object("invented/failed.env") ])
    client.stub_responses(:get_object, [
      { body: contents["invented/.env"], etag: '"changed"', last_modified: modified }, "AccessDenied"
    ])

    refresh

    expect(document.at_css(".flash-error").text).to include("S3 refresh failed")
    expect(EnvFile.first!.attributes).to eq(file.attributes)
  end

  [
    [ Aws::Errors::MissingRegionError, "Set AWS_REGION before refreshing from S3." ],
    [ Aws::Errors::MissingCredentialsError, "Configure AWS credentials before refreshing from S3." ]
  ].each do |error, message|
    it "shows a flash for #{error}" do
      allow(EnvFileRefresh).to receive(:client).and_raise(error)

      refresh

      expect(document.at_css(".flash-error").text).to eq(message)
      expect(EnvFile.count).to eq(0)
    end
  end

  it "shows a flash when the encryption key is missing, including with existing snapshots" do
    refresh
    config = ActiveRecord::Encryption.config
    original_key = config.primary_key
    config.primary_key = nil

    refresh

    expect(document.at_css(".flash-error").text).to include("ENVS_ENCRYPTION_KEY")
    expect(document.at_css(".blankslate").text).to include("Snapshots unavailable")
    get env_file_path(EnvFile.first!)
    expect(response).to redirect_to(root_path)
  ensure
    config.primary_key = original_key if config
  end

  it "does not log values or file content" do
    output = StringIO.new
    logger = ActiveSupport::Logger.new(output)
    original_logger = ActiveRecord::Base.logger
    ActiveRecord::Base.logger = logger
    allow(Rails).to receive(:logger).and_return(logger)

    refresh
    get env_file_path(EnvFile.first!)

    expect(output.string).not_to include("invented-value", "FIRST=invented")
  ensure
    ActiveRecord::Base.logger = original_logger
  end
end
