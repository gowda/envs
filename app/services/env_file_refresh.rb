class EnvFileRefresh
  def self.client
    Aws::S3::Client.new
  end

  def self.call(bucket:, prefix:)
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
    replace(file, content, etag: response.etag, last_modified: response.last_modified)
    content
  end

  def self.replace(file, text, **attributes)
    result = EnvFileContents.call(text)
    file.update!(**attributes, too_large: text.bytesize > EnvFileContents::MAX_BYTES,
      parse_error: result.error, unassigned_lines: result.unassigned_lines,
      deleted_in_s3: false, fetched_at: Time.current)
    return if result.error

    types = file.variables.reset.pluck(:name, :value_type).to_h
    remaining = result.entries.map(&:name).to_set
    pending_types = file.pending_edits.pluck(:name, :value_type) + file.pending_choices.pluck(:name, :value_type)
    pending_types.each do |name, type|
      current_type = remaining.include?(name) ? types[name] : nil
      EnvFileValueTypes.store(file, name, current_type) if type != current_type
    end
    file.variables.delete_all
    result.entries.each_with_index do |entry, position|
      file.variables.create!(position: position, line_number: entry.line_number,
        name: entry.name, value_type: types[entry.name], value: entry.value)
    end
    file.variables.reset
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
      file.update!(too_large: true, parse_error: EnvFileContents::TOO_LARGE_MESSAGE, deleted_in_s3: false,
        etag: object.etag, last_modified: object.last_modified, fetched_at: Time.current)
    else
      response = @client.get_object(bucket: @bucket, key: object.key)
      self.class.apply(file, response)
    end
  end
end
