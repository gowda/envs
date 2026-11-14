module S3Files
  def create_env_file(content:, **attributes)
    file = EnvFile.create!(**attributes)
    update_env_file(file, content: content)
    file
  end

  def update_env_file(file, **attributes)
    if attributes.key?(:content)
      text = attributes.delete(:content).to_s
      EnvFileRefresh.replace(file, text, **attributes.slice(:etag, :last_modified))
      @s3_texts ||= {}
      @s3_texts[file.key] = text
      client.stub_responses(:get_object, ->(context) {
        current = EnvFile.find_by!(bucket: context.params[:bucket], key: context.params[:key])
        { body: @s3_texts.fetch(current.key), etag: current.etag,
          content_type: "text/plain", metadata: { "invented" => "metadata" },
          server_side_encryption: "aws:kms", ssekms_key_id: "invented-kms-key" }
      })
    end
    file.update!(attributes) if attributes.any?
    file.reload
  end

  def snapshot_entries(file)
    file.reload.parsed_contents.entries
  end

  def entries_from(text)
    EnvFileContents.call(text).entries
  end
end

RSpec.configure do |config|
  config.include S3Files, type: :request
  config.before(type: :request) { Aws.config[:s3] = { stub_responses: true } }
  config.after(type: :request) { Aws.config.delete(:s3) }
end
