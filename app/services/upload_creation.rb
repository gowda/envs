class UploadCreation
  Result = Data.define(:upload, :error)

  def self.call(file)
    unless file.is_a?(ActionDispatch::Http::UploadedFile)
      return Result.new(nil, "Choose an env file to upload.")
    end

    contents = file.read(EnvFileContents::MAX_BYTES + 1).to_s
    result = EnvFileContents.call(contents)
    return Result.new(nil, result.error) if result.error

    upload = Upload.new
    upload.file.attach(io: StringIO.new(contents), filename: file.original_filename, content_type: "text/plain", identify: false)
    upload.save!
    Result.new(upload, nil)
  end
end
