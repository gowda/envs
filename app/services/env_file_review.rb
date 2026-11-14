class EnvFileReview
  def self.call(file, client: nil)
    EnvFileConflicts.ensure_publishable!(file)
    client ||= EnvFileRefresh.client
    response = client.get_object(bucket: file.bucket, key: file.key)
    text = response.body.read(EnvFileContents::MAX_BYTES + 1).to_s
    result = EnvFileContents.call(text)
    unless response.etag == file.etag && !result.error && result.entries == file.parsed_contents.entries
      EnvFileRefresh.replace(file, text, etag: response.etag, last_modified: response.last_modified)
      return [ :changed, response ]
    end
    [ EnvFileRewrite.rewrite(file, text: text), response ]
  rescue Aws::S3::Errors::NoSuchKey, Aws::S3::Errors::NotFound
    file.update!(deleted_in_s3: true)
    [ :deleted, nil ]
  end
end
