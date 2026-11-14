require "rails_helper"

RSpec.describe "Env uploads", type: :request do
  def upload(text)
    file = Rack::Test::UploadedFile.new(StringIO.new(text), "text/plain", true, original_filename: "invented.env")
    post files_path, params: { file: file }
    if response.status == 303
      expect(response).to redirect_to(file_path(Upload.last!))
      follow_redirect!
    end
  end

  def document
    Nokogiri::HTML5(response.body)
  end

  it "shows a hidden file field, one centred button and only importmap scripts" do
    get files_path

    expect(response).to have_http_status(:ok)
    expect(document.css('input[type="file"]').size).to eq(1)
    expect(document.at_css('input[type="file"]')['hidden']).not_to be_nil
    expect(document.css('button').map(&:text)).to eq([ 'Select an env file' ])
    expect(document.text).to include('Drag an env file anywhere to upload')
    expect(document.css('.upload-page .Box')).to be_empty
    expect(document.css('script').any? { |tag| tag['src'] || tag.text.include?('turbo') }).to be(false)
    expect(document.css('*').flat_map { |node| node.attribute_nodes.map(&:name) }.grep(/\Aon/i)).to be_empty
    expect(document.css("script").map { |tag| tag["type"] }).to eq(%w[importmap module])
    expect(document.at_css("html").attributes.slice("data-color-mode", "data-light-theme", "data-dark-theme").transform_values(&:value))
      .to eq("data-color-mode" => "auto", "data-light-theme" => "light", "data-dark-theme" => "dark")
    expect(document.css('link[rel="stylesheet"]').map { |link| link["href"] }).to match([
      a_string_matching(%r{/assets/primer-}), a_string_matching(%r{/assets/application-})
    ])
  end

  it "links exactly one SVG favicon for each colour scheme" do
    get files_path

    icons = document.css('link[rel="icon"]')
    expect(icons.size).to eq(2)
    expect(icons.map { |icon| [ icon["href"], icon["media"], icon["type"] ] }).to eq([
      [ "/filled-light-mode.svg", "(prefers-color-scheme: light)", "image/svg+xml" ],
      [ "/filled-dark-mode.svg", "(prefers-color-scheme: dark)", "image/svg+xml" ]
    ])
    expect(document.css('link[href="/icon.png"], link[href="/icon.svg"]')).to be_empty
  end

  it "redirects the root to the upload page" do
    get root_path
    expect(response).to have_http_status(:found)
    expect(response).to redirect_to(files_path)
  end

  it "stores a valid file and redirects to its public ID" do
    file = Rack::Test::UploadedFile.new(StringIO.new("INVENTED=value"), "text/plain", true, original_filename: "invented.env")
    expect { post files_path, params: { file: file } }.to change(Upload, :count).by(1)
    stored = Upload.last!
    expect(response).to have_http_status(:see_other)
    expect(response).to redirect_to("/files/" + stored.public_id)
    expect(stored.public_id.length).to eq(24)
    expect(stored.file.download).to eq("INVENTED=value")
    get file_path(stored)
    expect(response).to have_http_status(:ok)
    expect(document.text).to include("INVENTED", "value")
    expect(document.css('a[href*="active_storage"]')).to be_empty
  end

  it "returns 404 for an unknown public ID or a numeric database ID" do
    get file_path("unknown-public-id")
    expect(response).to have_http_status(:not_found)
    upload("INVENTED=value")
    get file_path(Upload.last!.id)
    expect(response).to have_http_status(:not_found)
  end

  it "stores no record or file for an invalid upload" do
    records = [ Upload.count, ActiveStorage::Blob.count, ActiveStorage::Attachment.count ]
    files = Dir.glob(Rails.root.join("tmp/storage/**/*")).select { |path| File.file?(path) }
    upload('{"invented":"value"}')
    expect(response).to have_http_status(:unprocessable_content)
    expect([ Upload.count, ActiveStorage::Blob.count, ActiveStorage::Attachment.count ]).to eq(records)
    expect(Dir.glob(Rails.root.join("tmp/storage/**/*")).select { |path| File.file?(path) }).to eq(files)
  end

  it "marks the upload section and uses the lowercase brand" do
    get files_path
    expect(document.css("header a.Header-link").map { |link| [ link.text, link["href"] ] }).to eq([
      [ "File upload", files_path ], [ "Amazon S3", s3_path ]
    ])
    expect(document.css('header [aria-current="page"]').map(&:text)).to eq([ "File upload" ])
    expect(document.css("header img").size).to eq(1)
    expect(document.at_css("header img")["alt"]).to eq("envs")
    expect(document.at_css("header img")["height"]).to eq("32")
    expect(document.at_css("header img").parent["href"]).to eq(files_path)
    expect(document.css("header span")).to be_empty
    expect(document.at_css("header").text).not_to include("envs")
    expect(document.at_css("title").text).to eq("File upload · envs")
    upload("INVENTED=value")
    expect(document.css('header [aria-current="page"]').map(&:text)).to eq([ "File upload" ])
    expect(document.at_css("title").text).to eq("invented.env · envs")
  end

  it "shows an error for a stored upload that no longer meets the rules" do
    stored = Upload.new
    stored.file.attach(io: StringIO.new("GOOD=invented\nA B=private-value"), filename: "old.env", content_type: "text/plain")
    stored.save!

    get file_path(stored)

    expect(response).to have_http_status(:ok)
    expect(document.at_css(".flash-error").text).to eq("Line 2: the name holds a space.")
    expect(document.text).not_to include("private-value")
    expect(document.css("section")).to be_empty
  end

  it "asks for a file when no file is uploaded" do
    post files_path

    expect(response).to have_http_status(:unprocessable_content)
    expect(document.at_css(".flash-error").text).to eq("Choose an env file to upload.")
  end
end
