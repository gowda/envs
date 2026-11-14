class EnvFilesController < ApplicationController
  before_action :prevent_caching
  before_action :load_file, only: %i[show edit update_edit delete_edit choice update_choice delete_choice discard review publish update_value_type]
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
  rescue_from EnvFileEditing::StaleSnapshot, with: :stale_edit

  def index
    @bucket = ENV["ENVS_S3_BUCKET"].presence
    @env_files = EnvFile.where(bucket: @bucket).includes(:pending_edits, :pending_choices).order(:key)
  end

  def show
    @value_types = EnvFileValueTypes.new(@env_file)
    @result = @env_file.parsed_contents
    @edits = @env_file.pending_edits.index_by(&:name)
    conflicts = EnvFileConflicts.new(@env_file)
    @choices = conflicts.active_choices.index_by(&:name)
    @conflicts = conflicts.all
  end

  def edit
    load_entry
    @value = @edit ? @edit.value : @entry.value
  rescue EnvFileEditing::MissingVariable
    raise ActiveRecord::RecordNotFound, cause: nil
  end

  def update_value_type
    input = params.permit(:name, :value_type, :dismiss)
    message = EnvFileValueTypes.save(@env_file, name: input[:name], value_type: input[:value_type], dismiss: input[:dismiss] == "1")
    redirect_to s3_file_path(@env_file), notice: message
  end

  def update_edit
    load_entry
    @value = params.permit(:value).fetch(:value).dup.force_encoding(Encoding::UTF_8)
    EnvFileEditing.save(@env_file, name: @name, value: @value, etag: params.permit(:etag)[:etag])
    redirect_to s3_file_path(@env_file), notice: "Saved the local change."
  end

  def delete_edit
    EnvFileEditing.delete(@env_file, name: params.permit(:name).fetch(:name))
    redirect_to s3_file_path(@env_file), notice: "Discarded the local change."
  end

  def choice
    @name = params.permit(:name).fetch(:name)
    @entries = EnvFileChoices.entries(@env_file, @name)
    @choice = @env_file.pending_choices.find_by(name: @name)
    @conflicted = @choice && EnvFileConflicts.new(@env_file).choice_conflict?(@choice)
    @selected = @choice && !@conflicted ? @choice.kept_entry(@entries) : @entries.last
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
    redirect_to @env_file.destroyed? ? s3_path : s3_file_path(@env_file), notice: "Discarded the local changes."
  end

  def review
    result, = @env_file.with_lock { EnvFileReview.call(@env_file) }
    return changed_file(result) if result.is_a?(Symbol)

    @rows = EnvFileDiff.call(result.operations)
  end

  def publish
    result = EnvFilePublish.call(@env_file)
    if result == :published
      redirect_to s3_file_path(@env_file), notice: "Published the env file to S3."
    else
      changed_file(result)
    end
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

  def changed_file(result)
    message = result == :deleted ? "This file is no longer in S3." : "The file changed in S3. Check your changes."
    redirect_to s3_file_path(@env_file), alert: message
  end

  def load_file
    @env_file = EnvFile.where(bucket: ENV["ENVS_S3_BUCKET"].presence).find(params[:id])
  end

  def load_entry
    @name = params.permit(:name).fetch(:name)
    @entry = EnvFileEditing.entry_for_name(@env_file, @name)
    @value_type = EnvFileValueTypes.new(@env_file).types.fetch(@name, "plain")
    @edit = @env_file.pending_edits.find_by(name: @name)
    @conflicted = @edit && EnvFileConflicts.new(@env_file).edit_conflict?(@edit)
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

  def stale_edit(error)
    load_entry
    @value = @value.to_s.scrub
    @error = error.message
    render :edit, status: :unprocessable_content
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
    message = "Set ENVS_ENCRYPTION_KEY to read and save secret values."
    if action_name == "index"
      @encryption_missing = true
      flash.now[:alert] = message
      render :index
    else
      redirect_to s3_path, alert: message
    end
  end
end
