require "rails_helper"

RSpec.describe "Dotenv uploads", type: :request do
  def upload(text)
    file = Rack::Test::UploadedFile.new(StringIO.new(text), "text/plain", true, original_filename: "invented.env")
    post upload_path, params: { file: file }
  end

  def document
    Nokogiri::HTML5(response.body)
  end

  it "shows one file field, one submit button, Primer and no script" do
    get upload_path

    expect(response).to have_http_status(:ok)
    expect(document.css('input[type="file"]').size).to eq(1)
    expect(document.css('input[type="submit"]').size).to eq(1)
    expect(document.css("script")).to be_empty
    expect(document.at_css("html").attributes.slice("data-color-mode", "data-light-theme", "data-dark-theme").transform_values(&:value))
      .to eq("data-color-mode" => "auto", "data-light-theme" => "light", "data-dark-theme" => "dark")
    expect(document.css('link[rel="stylesheet"]').map { |link| link["href"] }).to match([
      a_string_matching(%r{/assets/primer-}), a_string_matching(%r{/assets/application-})
    ])
  end

  it "shows ordered single-line and multiline values, with escaped HTML" do
    upload("ZEBRA=first\nALPHA=\"line one\n<script>alert('invented')</script>\"\n")

    expect(response).to have_http_status(:ok)
    rows = document.css("section .Box-row")
    expect(rows.size).to eq(2)
    expect(rows.first.css("div").map(&:text)).to eq([ "ZEBRA", "first" ])
    expect(rows.last.at_css("pre").text).to eq("line one\n<script>alert('invented')</script>")
    expect(response.body.index("ZEBRA")).to be < response.body.index("ALPHA")
    expect(document.css("script")).to be_empty
    expect(response.headers["Cache-Control"]).to eq("no-store")
    expect(ENV).not_to have_key("ZEBRA")
  end

  it "keeps commands and variable references literal without running commands" do
    marker = Rails.root.join("tmp", "dotenv-command-#{SecureRandom.hex}")
    substitutions = Dotenv::Parser.substitutions.dup
    upload("COMMAND=$(touch #{marker})\nREFERENCE=$PATH\nBRACED=${PATH}\n")

    expect(response).to have_http_status(:ok)
    expect(document.text).to include("$(touch #{marker})", "$PATH", "${PATH}")
    expect(File.exist?(marker)).to be(false)
    expect(Dotenv::Parser.substitutions).to eq(substitutions)
  ensure
    File.delete(marker) if marker && File.exist?(marker)
  end

  it "shows the uploaded value even when the server has the same key" do
    upload("PATH=invented-upload-path\n")

    expect(response).to have_http_status(:ok)
    expect(document.css("section .Box-row").first.text).to include("invented-upload-path")
    expect(ENV.fetch("PATH")).not_to eq("invented-upload-path")
  end

  [ '{"invented":"value"}', "<html>invented</html>", "hello world", "GOOD=value\ninvalid line", "export UNSET_INVENTED" ].each do |text|
    it "rejects invalid dotenv text #{text.inspect}" do
      upload(text)

      expect(response).to have_http_status(:unprocessable_content)
      expect(document.at_css(".flash-error").text).to eq(DotenvContents::INVALID_MESSAGE)
      expect(document.css('input[type="file"]').size).to eq(1)
      expect(document.css("section .Box-row")).to be_empty
    end
  end

  [ "", "  \n# invented comment\n" ].each do |text|
    it "rejects a file without variables #{text.inspect}" do
      upload(text)

      expect(response).to have_http_status(:unprocessable_content)
      expect(document.at_css(".flash-error").text).to eq(DotenvContents::INVALID_MESSAGE)
    end
  end

  it "rejects invalid UTF-8" do
    upload("KEY=\xFF".b)

    expect(response).to have_http_status(:unprocessable_content)
    expect(document.at_css(".flash-error").text).to include("valid UTF-8")
  end

  it "rejects a file over 1 MB" do
    upload("KEY=" + "a" * DotenvContents::MAX_BYTES)

    expect(response).to have_http_status(:unprocessable_content)
    expect(document.at_css(".flash-error").text).to include("1 MB or smaller")
  end

  it "accepts a file exactly 1 MB" do
    upload("KEY=" + "a" * (DotenvContents::MAX_BYTES - 4))

    expect(response).to have_http_status(:ok)
  end

  it "accepts comments, CRLF, bare keys and multiline values with dotenv-like lines" do
    upload("# invented\r\nBARE\r\nMULTI=\"first\r\nhello world\r\n# still a value\"\r\n")

    expect(response).to have_http_status(:ok)
    expect(document.at_css("pre").text).to eq("first\nhello world\n# still a value")
    expect(document.css("section .Box-row").first.css("div").map(&:text)).to eq([ "BARE", "" ])
  end

  [
    [ 'A="closed"', "closed" ],
    [ "A='closed'", "closed" ],
    [ "A=\"first\nsecond\"", "first\nsecond" ],
    [ 'A="with \" escaped"', 'with " escaped' ],
    [ 'A="closed" # comment', "closed" ],
    [ 'A=plain "inner" text', 'plain "inner" text' ],
    [ 'A=""', "" ],
    [ "A=", "" ]
  ].each do |text, value|
    it "accepts the valid value in #{text.inspect}" do
      upload(text)

      expect(response).to have_http_status(:ok)
      expect(document.at_css("section .Box-row .col-8, section .Box-row pre").text).to eq(value)
    end
  end

  [ 'A="unterminated', "A='unterminated", 'A="x" garbage', 'A="one" "two"', "A=\"unterminated\nOTHER=value\n" ].each do |text|
    it "rejects the malformed quoted value in #{text.inspect}" do
      upload(text)

      expect(response).to have_http_status(:unprocessable_content)
      expect(document.at_css(".flash-error").text).to eq(DotenvContents::INVALID_MESSAGE)
      expect(document.css("section .Box-row")).to be_empty
    end
  end

  it "preserves the leading newline of a multiline value" do
    upload("A=\"\nfirst\nsecond\"\n")

    expect(response).to have_http_status(:ok)
    expect(response.body).to match(/<pre\b[^>]*>\n\nfirst\nsecond<\/pre>/)
  end

  it "asks for a file when no file is uploaded" do
    post upload_path

    expect(response).to have_http_status(:unprocessable_content)
    expect(document.at_css(".flash-error").text).to eq("Choose a dotenv file to upload.")
  end
end
