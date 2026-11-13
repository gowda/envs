class UploadsController < ApplicationController
  def new
  end

  def create
    response.headers["Cache-Control"] = "no-store"
    file = params.permit(:file)[:file]
    result = if file.is_a?(ActionDispatch::Http::UploadedFile)
      DotenvContents.call(file.read(DotenvContents::MAX_BYTES + 1).to_s)
    else
      DotenvContents::Result.new(nil, "Choose a dotenv file to upload.")
    end
    @variables = result.variables
    @error = result.error
    render :new, status: @error ? :unprocessable_content : :ok
  end
end
