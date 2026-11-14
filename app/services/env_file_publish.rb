class EnvFilePublish
  def self.client
    Aws::S3::Client.new
  end

  def self.call(file)
    file.with_lock do
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
  end
end
