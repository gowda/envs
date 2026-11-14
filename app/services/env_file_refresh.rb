class EnvFileRefresh
  def self.client
    Aws::S3::Client.new
  end

  def self.call(bucket:, prefix:)
    ActiveRecord::Encryption.config.primary_key
    new(client, bucket, prefix).call
  end

  def self.one(file, client:)
    file.with_lock do
      response = client.get_object(bucket: file.bucket, key: file.key)
      apply(file, response)
    end
  rescue Aws::S3::Errors::NoSuchKey, Aws::S3::Errors::NotFound
    file.update!(deleted_in_s3: true)
  end

  def self.apply(file, response)
    content = response.body.read(EnvFileContents::MAX_BYTES + 1).to_s
    too_large = content.bytesize > EnvFileContents::MAX_BYTES
    file.update!(content: too_large ? nil : content, too_large: too_large, deleted_in_s3: false,
      etag: response.etag, last_modified: response.last_modified, fetched_at: Time.current)
    EnvFileEditing.reconcile(file)
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
      EnvFile.where(bucket: @bucket).where.not(key: keys).find_each do |file|
        file.pending_changes? ? file.update!(deleted_in_s3: true) : file.destroy!
      end
    end
    keys.size
  end

  private

  def env_key?(key)
    name = File.basename(key)
    !key.end_with?("/") && (name == ".env" || name.start_with?(".env.") || name.end_with?(".env"))
  end

  def save_snapshot(object)
    file = EnvFile.find_or_initialize_by(bucket: @bucket, key: object.key)
    if object.size > EnvFileContents::MAX_BYTES
      file.update!(content: nil, too_large: true, deleted_in_s3: false,
        etag: object.etag, last_modified: object.last_modified, fetched_at: Time.current)
    else
      response = @client.get_object(bucket: @bucket, key: object.key)
      self.class.apply(file, response)
    end
  end
end
