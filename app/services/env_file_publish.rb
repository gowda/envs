class EnvFilePublish
  def self.client
    Aws::S3::Client.new
  end

  def self.call(file)
    client = nil
    outcome = file.with_lock do
      EnvFileConflicts.ensure_publishable!(file)
      raise EnvFileRewrite::Invalid, "There are no changes to publish." unless file.pending_changes?

      raise EnvFileRewrite::Invalid, "Refresh the file to obtain its ETag before publishing." if file.etag.blank?

      client = self.client
      rewrite, settings = EnvFileReview.call(file, client: client)
      next rewrite if rewrite.is_a?(Symbol)
      text = rewrite.text
      response = client.put_object(**{
        bucket: file.bucket, key: file.key, body: text, if_match: file.etag,
        content_type: settings.content_type, metadata: settings.metadata,
        server_side_encryption: settings.server_side_encryption, ssekms_key_id: settings.ssekms_key_id
      }.compact)
      now = Time.current
      file.pending_edits.delete_all
      file.pending_choices.delete_all
      file.pending_edits.reset
      file.pending_choices.reset
      EnvFileRefresh.replace(file, text, etag: response.etag, last_modified: now)
      :published
    end
    outcome
  rescue Aws::S3::Errors::PreconditionFailed
    EnvFileRefresh.one(file, client: client)
    file.deleted_in_s3? ? :deleted : :changed
  rescue Aws::S3::Errors::NoSuchKey, Aws::S3::Errors::NotFound
    file.update!(deleted_in_s3: true)
    :deleted
  end
end
