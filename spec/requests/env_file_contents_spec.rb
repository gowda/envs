require "rails_helper"

RSpec.describe "Container env file contents", type: :request do
  def document
    Nokogiri::HTML5(response.body)
  end

  [ :upload, :s3 ].each do |source|
    context "from #{source}" do
      def show_contents(text)
        if source == :upload
          file = Rack::Test::UploadedFile.new(StringIO.new(text), "text/plain", true, original_filename: "invented.env")
          post files_path, params: { file: file }
          if response.status == 303
            follow_redirect!
          else
            expect(response).to have_http_status(:unprocessable_content)
          end
        else
          client = Aws::S3::Client.new(stub_responses: true, region: "us-east-1")
          allow(EnvFileRefresh).to receive(:client).and_return(client)
          client.stub_responses(:list_objects_v2, contents: [ { key: "invented.env", size: text.bytesize } ])
          client.stub_responses(:get_object, body: text)
          post refresh_s3_path
          get s3_file_path(EnvFile.last!)
        end
      end

      let(:source) { source }

      around do |example|
        previous = ENV["ENVS_S3_BUCKET"]
        ENV["ENVS_S3_BUCKET"] = "invented-bucket"
        example.run
      ensure
        previous ? ENV["ENVS_S3_BUCKET"] = previous : ENV.delete("ENVS_S3_BUCKET")
      end

      it "preserves literal values, empty values and file order in two columns" do
        values = [ '"quoted"', '"quoted" # note', '  spaced  ', 'a=b=c', '"a","b"', '', '<script>invented</script>', 'a\\nb' ]
        show_contents(values.each_with_index.map { |value, index| "KEY#{index}=#{value}\n" }.join)

        expect(response).to have_http_status(:ok)
        rows = document.css("section .Box-row")
        expect(rows.map { |row| row.at_css(".col-4").text }).to eq(values.each_index.map { |index| "KEY#{index}" })
        expect(rows.map { |row| row.at_css(".col-8").text }).to eq(values)
        expect(rows.all? { |row| row.element_children.size == 2 }).to be(true)
        expect(document.css("pre")).to be_empty
        expect(document.css("script").map { |tag| tag["type"] }).to eq(%w[importmap module])
      end

      it "removes the first BOM and CRLF endings and skips indented comments and blank lines" do
        show_contents("\uFEFF  FIRST=value\r\n \t# comment\r\n \t\r\nSECOND=two\r\n")

        expect(response).to have_http_status(:ok)
        expect(document.css("section .col-4").map(&:text)).to eq(%w[FIRST SECOND])
        expect(document.css("section .col-8").map(&:text)).to eq(%w[value two])
      end

      it "keeps a BOM on later lines" do
        show_contents("FIRST=value\n\uFEFFSECOND=two\n")

        expect(document.css("section .col-4").map(&:text)).to eq([ "FIRST", "\uFEFFSECOND" ])
      end

      it "keeps and labels each duplicate and counts entries on S3 cards" do
        show_contents("SAME=one\nOTHER=middle\nSAME=two\n")

        rows = document.css("section .Box-row")
        expect(rows.map { |row| row.at_css(".col-8").text }).to eq(%w[one middle two])
        expect(rows.map { |row| row.css(".Label").map(&:text) }).to eq([ [ "Duplicate" ], [], [ "Duplicate" ] ])
        expect(document.at_css("section .Box-title .Label").text).to eq("3")
        if source == :s3
          get s3_path
          expect(document.at_css("a.Box").text).to include("3 variables")
        end
      end

      it "warns about lines without = and does not use the host environment" do
        show_contents("PATH\nKEY=value\nUNSET_INVENTED\nno assignment\n")

        expect(response).to have_http_status(:ok)
        expect(document.css("section .col-4").map(&:text)).to eq([ "KEY" ])
        warning = document.at_css(".flash-warn")
        expect(warning.text).to eq("Lines 1, 3, 4 have no =. A container gets no value from these lines.")
        expect(response.body.index('class="flash flash-warn')).to be < response.body.index('<section')
      end

      it "does not join quoted lines" do
        show_contents("KEY=\"first\nsecond\"\nNEXT=last\n")

        expect(document.css("section .col-8").map(&:text)).to eq([ '"first', "last" ])
        expect(document.at_css(".flash-warn").text).to include("Lines 2 have no =")
      end

      it "shows commands and references literally without executing or loading them" do
        marker = Rails.root.join("tmp", "env-command-#{SecureRandom.hex}")
        show_contents("COMMAND=$(touch #{marker})\nREFERENCE=$PATH\nBRACED=${PATH}\nPATH=invented-path\n")

        expect(document.css("section .col-8").map(&:text)).to eq([ "$(touch #{marker})", "$PATH", "${PATH}", "invented-path" ])
        expect(File.exist?(marker)).to be(false)
        expect(ENV.fetch("PATH")).not_to eq("invented-path")
      ensure
        File.delete(marker) if marker && File.exist?(marker)
      end

      [
        [ "=private-value", "the name before = is empty." ],
        [ "A B=private-value", "the name holds a space." ],
        [ "KEY =private-value", "the name holds a space." ],
        [ "A\tB=private-value", "the name holds a tab." ],
        [ "KEY=" + "private-value" * 5_042, "the line exceeds 65,536 bytes." ],
        [ "KEY=\xFF".b, "the line must use valid UTF-8 encoding." ]
      ].each do |line, reason|
        it "rejects #{reason} with a line number and no value" do
          show_contents("GOOD=invented\n".b + line.b)

          expect(document.at_css(".flash-error").text).to eq("Line 2: #{reason}")
          expect(document.text).not_to include("private-value")
          expect(document.css("section")).to be_empty
        end
      end

      [ "", " \n  # comment\n", "PATH\n" ].each do |text|
        it "rejects a file with no entry: #{text.inspect}" do
          show_contents(text)

          expect(document.at_css(".flash-error").text).to eq(EnvFileContents::INVALID_MESSAGE)
          expect(document.css("section")).to be_empty
        end
      end

      it "accepts a line of exactly 65,536 bytes" do
        show_contents("KEY=" + "a" * 65_532)

        expect(response).to have_http_status(:ok)
        expect(document.at_css("section .col-8").text).to eq("a" * 65_532)
      end

      it "accepts a file of exactly 1 MB with valid line sizes" do
        show_contents(("KEY=" + "a" * 65_531 + "\n") * 16)

        expect(response).to have_http_status(:ok)
        expect(document.css("section .Box-row").size).to eq(16)
      end

      it "rejects a file over 1 MB" do
        show_contents("KEY=" + "a" * EnvFileContents::MAX_BYTES)

        expect(document.at_css(".flash-error").text).to eq(EnvFileContents::TOO_LARGE_MESSAGE)
      end
    end
  end
end
