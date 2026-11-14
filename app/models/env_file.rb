class EnvFile < ApplicationRecord
  encrypts :content
  has_many :pending_edits, dependent: :delete_all

  def file_name
    File.basename(key)
  end

  def parsed_contents
    if too_large?
      EnvFileContents::Result.new([], EnvFileContents::TOO_LARGE_MESSAGE, [])
    else
      EnvFileContents.call(content.to_s)
    end
  end
end
