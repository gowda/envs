class EnvFile < ApplicationRecord
  encrypts :content

  def file_name
    File.basename(key)
  end

  def parsed_contents
    if too_large?
      DotenvContents::Result.new(nil, DotenvContents::TOO_LARGE_MESSAGE)
    else
      DotenvContents.call(content.to_s)
    end
  end
end
