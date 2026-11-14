class EnvFilePublish
  def self.client
    Aws::S3::Client.new
  end

  def self.call(file)
    client = nil
    file.with_lock do
      EnvFileConflicts.ensure_publishable!(file)
      raise EnvFileRewrite::Invalid, "There are no changes to publish." unless file.pending_changes?

      raise EnvFileRewrite::Invalid, "Refresh the file to obtain its ETag before publishing." if file.etag.blank?

      text = EnvFileRewrite.call(file)
      client = self.client
      settings = client.head_object(bucket: file.bucket, key: file.key)
      response = client.put_object(**{
        bucket: file.bucket, key: file.key, body: text, if_match: file.etag,
        content_type: settings.content_type, metadata: settings.metadata,
        server_side_encryption: settings.server_side_encryption, ssekms_key_id: settings.ssekms_key_id
      }.compact)
      now = Time.current
      file.update!(content: text, etag: response.etag, last_modified: now, fetched_at: now)
      file.pending_edits.delete_all
      file.pending_choices.delete_all
    end
    :published
  rescue Aws::S3::Errors::PreconditionFailed
    EnvFileRefresh.one(file, client: client)
    file.deleted_in_s3? ? :deleted : :changed
  rescue Aws::S3::Errors::NoSuchKey, Aws::S3::Errors::NotFound
    file.update!(deleted_in_s3: true)
    :deleted
  end
end
