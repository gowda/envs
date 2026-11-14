class EnvFileValueTypes
  def self.save(file, name:, value_type:, dismiss: false)
    file.with_lock do
      EnvFileEditing.entry_for_name(file, name)
      unless VariableType.value_types.key?(value_type)
        raise EnvFileRewrite::Invalid, "Choose secret or plain."
      end
      if dismiss && value_type != "plain"
        raise EnvFileRewrite::Invalid, "Dismiss a suggestion as plain."
      end

      row = VariableType.find_or_initialize_by(bucket: file.bucket, key: file.key, name: name)
      row.update!(value_type: value_type)
    end
    message_name = name.length > 80 ? "#{name.first(80)}…" : name
    dismiss ? "Dismissed the suggestion for #{message_name}." : "Marked #{message_name} as #{value_type}."
  end

  def initialize(file)
    @file = file
  end

  def types
    @types ||= VariableType.where(bucket: @file.bucket, key: @file.key).pluck(:name, :value_type).to_h
  end

  def suggestions
    result = @file.parsed_contents
    return [] if @file.deleted_in_s3? || result.error

    result.entries.map(&:name).uniq.select { |name| !types.key?(name) && SecretName.match?(name) }
  end
end
