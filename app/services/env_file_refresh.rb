class EnvFileRefresh
  def self.client
    Aws::S3::Client.new
  end

  def self.call(bucket:, prefix:)
    ActiveRecord::Encryption.config.primary_key
    new(client, bucket, prefix).call
  end

  def initialize(client, bucket, prefix)
    @client = client
    @bucket = bucket
    @prefix = prefix
  end

  def call
    keys = []
    EnvFile.transaction do
      @client.list_objects_v2(bucket: @bucket, prefix: @prefix).each_page do |page|
        page.contents.each do |object|
          next unless env_key?(object.key)

          keys << object.key
          save_snapshot(object)
        end
      end
      EnvFile.where(bucket: @bucket).where.not(key: keys).delete_all
    end
    keys.size
  end

  private

  def env_key?(key)
    name = File.basename(key)
    !key.end_with?("/") && (name == ".env" || name.start_with?(".env.") || name.end_with?(".env"))
  end

  def save_snapshot(object)
    attributes = { etag: object.etag, last_modified: object.last_modified, fetched_at: Time.current }
    if object.size > EnvFileContents::MAX_BYTES
      attributes.merge!(content: nil, too_large: true)
    else
      response = @client.get_object(bucket: @bucket, key: object.key)
      content = response.body.read(EnvFileContents::MAX_BYTES + 1).to_s
      too_large = content.bytesize > EnvFileContents::MAX_BYTES
      attributes.merge!(content: too_large ? nil : content, too_large: too_large,
        etag: response.etag, last_modified: response.last_modified)
    end
    file = EnvFile.find_or_initialize_by(bucket: @bucket, key: object.key)
    file.update!(attributes)
    EnvFileEditing.reconcile(file)
  end
end
