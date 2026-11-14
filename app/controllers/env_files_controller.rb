class EnvFilesController < ApplicationController
  before_action :prevent_caching
  before_action :load_file, only: %i[show edit update_edit choice update_choice delete_choice discard review publish]
  param_encoding :update_edit, :value, Encoding::ASCII_8BIT
  rescue_from EnvFileRewrite::Invalid, with: :invalid_edit
  rescue_from EnvFileEditing::MissingVariable, with: :missing_variable
  rescue_from Aws::Errors::ServiceError, with: :aws_error
  rescue_from Aws::Errors::MissingRegionError, with: :missing_region
  rescue_from Aws::Errors::MissingCredentialsError, with: :missing_credentials
  rescue_from Seahorse::Client::NetworkingError, with: :networking_error
  rescue_from Aws::Errors::InvalidSSOToken, with: :expired_login
  rescue_from Aws::Errors::NoSuchProfileError, with: :missing_profile
  rescue_from ActiveRecord::Encryption::Errors::Configuration, with: :missing_encryption_key
  rescue_from Aws::S3::Errors::PreconditionFailed, with: :stale_snapshot

  def index
    @bucket = ENV["ENVS_S3_BUCKET"].presence
    @env_files = EnvFile.where(bucket: @bucket).includes(:pending_edits, :pending_choices).order(:key)
    ActiveRecord::Encryption.config.primary_key if @env_files.exists?
  end

  def show
    @result = @env_file.parsed_contents
    @edits = @env_file.pending_edits.index_by(&:name)
    @choices = @env_file.pending_choices.index_by(&:name)
  end

  def edit
    load_entry
    @value = @env_file.pending_edits.find_by(name: @name)&.value || @entry.value
  rescue EnvFileEditing::MissingVariable
    raise ActiveRecord::RecordNotFound, cause: nil
  end

  def update_edit
    load_entry
    @value = params.permit(:value).fetch(:value).dup.force_encoding(Encoding::UTF_8)
    EnvFileEditing.save(@env_file, name: @name, value: @value)
    redirect_to s3_file_path(@env_file), notice: "Saved the local change."
  end

  def choice
    @name = params.permit(:name).fetch(:name)
    @entries = EnvFileChoices.entries(@env_file, @name)
    @choice = @env_file.pending_choices.find_by(name: @name)
    @selected = @choice ? @choice.kept_entry(@entries) : @entries.last
  end

  def update_choice
    input = params.permit(:name, :line_number, :line_count)
    EnvFileChoices.save(@env_file, name: input.fetch(:name), line_number: input.fetch(:line_number), line_count: input.fetch(:line_count))
    redirect_to s3_file_path(@env_file), notice: "Saved the local choice."
  end

  def delete_choice
    EnvFileChoices.delete(@env_file, name: params.permit(:name).fetch(:name))
    redirect_to s3_file_path(@env_file), notice: "Kept every line."
  end

  def discard
    EnvFileEditing.discard(@env_file)
    redirect_to s3_file_path(@env_file), notice: "Discarded the local changes."
  end

  def review
    result = EnvFileRewrite.rewrite(@env_file)
    @rows = EnvFileDiff.call(result.operations)
  end

  def publish
    EnvFilePublish.call(@env_file)
    redirect_to s3_file_path(@env_file), notice: "Published the env file to S3."
  end

  def refresh
    bucket = ENV["ENVS_S3_BUCKET"].presence
    if bucket
      count = EnvFileRefresh.call(bucket: bucket, prefix: ENV.fetch("ENVS_S3_PREFIX", ""))
      redirect_to s3_path, notice: "Refreshed #{count} env #{"file".pluralize(count)} from S3."
    else
      redirect_to s3_path, alert: "Set ENVS_S3_BUCKET, AWS_REGION and ENVS_ENCRYPTION_KEY before refreshing."
    end
  end

  private

  def load_file
    ActiveRecord::Encryption.config.primary_key
    @env_file = EnvFile.where(bucket: ENV["ENVS_S3_BUCKET"].presence).find(params[:id])
  end

  def load_entry
    @name = params.permit(:name).fetch(:name)
    @entry = EnvFileEditing.entry_for_name(@env_file, @name)
  end

  def invalid_edit(error)
    if action_name == "update_edit" && @entry
      @error = error.message
      @value = @value.to_s.scrub
      render :edit, status: :unprocessable_content
    else
      redirect_to s3_file_path(@env_file), alert: error.message
    end
  end

  def missing_variable(error)
    redirect_to s3_file_path(@env_file), alert: error.message
  end

  def stale_snapshot
    redirect_to s3_file_path(@env_file), alert: "The file changed in S3. Refresh before publishing. Your edits are kept."
  end

  def s3_operation
    action_name == "publish" ? "publish" : "refresh"
  end

  def prevent_caching
    response.headers["Cache-Control"] = "no-store"
  end

  def aws_error(error)
    redirect_to s3_path, alert: "S3 #{s3_operation} failed (#{error.code})."
  end

  def networking_error
    redirect_to s3_path, alert: "S3 cannot be reached#{action_name == "publish" ? " for publish" : ""}."
  end

  def expired_login
    redirect_to s3_path, alert: "#{action_name == "publish" ? "S3 publish failed. " : ""}The AWS login has expired. Sign in again."
  end

  def missing_profile
    redirect_to s3_path, alert: "#{action_name == "publish" ? "S3 publish failed. " : ""}The AWS profile does not exist."
  end

  def missing_region
    redirect_to s3_path, alert: "Set AWS_REGION before #{action_name == "publish" ? "publishing to" : "refreshing from"} S3."
  end

  def missing_credentials
    redirect_to s3_path, alert: "Configure AWS credentials before #{action_name == "publish" ? "publishing to" : "refreshing from"} S3."
  end

  def missing_encryption_key
    message = "Set ENVS_ENCRYPTION_KEY to read and save snapshots."
    if action_name == "index"
      @encryption_missing = true
      flash.now[:alert] = message
      render :index
    else
      redirect_to s3_path, alert: message
    end
  end
end
