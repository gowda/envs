class EnvFilesController < ApplicationController
  before_action :prevent_caching
  rescue_from Aws::Errors::ServiceError, with: :aws_error
  rescue_from Aws::Errors::MissingRegionError, with: :missing_region
  rescue_from Aws::Errors::MissingCredentialsError, with: :missing_credentials
  rescue_from ActiveRecord::Encryption::Errors::Configuration, with: :missing_encryption_key

  def index
    @bucket = ENV["ENVS_S3_BUCKET"].presence
    @env_files = EnvFile.where(bucket: @bucket).order(:key)
    ActiveRecord::Encryption.config.primary_key if @env_files.exists?
  end

  def show
    ActiveRecord::Encryption.config.primary_key
    @env_file = EnvFile.where(bucket: ENV["ENVS_S3_BUCKET"].presence).find(params[:id])
    @result = @env_file.parsed_contents
  end

  def refresh
    bucket = ENV["ENVS_S3_BUCKET"].presence
    if bucket
      count = EnvFileRefresh.call(bucket: bucket, prefix: ENV.fetch("ENVS_S3_PREFIX", ""))
      redirect_to root_path, notice: "Refreshed #{count} dotenv files from S3."
    else
      redirect_to root_path, alert: "Set ENVS_S3_BUCKET, AWS_REGION and ENVS_ENCRYPTION_KEY before refreshing."
    end
  end

  private

  def prevent_caching
    response.headers["Cache-Control"] = "no-store"
  end

  def aws_error
    redirect_to root_path, alert: "S3 refresh failed. Check bucket access and try again."
  end

  def missing_region
    redirect_to root_path, alert: "Set AWS_REGION before refreshing from S3."
  end

  def missing_credentials
    redirect_to root_path, alert: "Configure AWS credentials before refreshing from S3."
  end

  def missing_encryption_key
    message = "Set ENVS_ENCRYPTION_KEY to read and save snapshots."
    if action_name == "index"
      @encryption_missing = true
      flash.now[:alert] = message
      render :index
    else
      redirect_to root_path, alert: message
    end
  end
end
