class UploadsController < ApplicationController
  before_action :prevent_caching

  def new
  end

  def create
    result = UploadCreation.call(params.permit(:file)[:file])
    if result.error
      @error = result.error
      render :new, status: :unprocessable_content
    else
      redirect_to file_path(result.upload), status: :see_other
    end
  end

  def show
    @upload = Upload.find_by!(public_id: params[:id])
    @variables = DotenvContents.call(@upload.file.download).variables
  end

  private

  def prevent_caching
    response.headers["Cache-Control"] = "no-store"
  end
end
