class EnvFileValueTypes
  def self.save(file, name:, value_type:, dismiss: false)
    file.with_lock do
      EnvFileEditing.entry_for_name(file, name)
      unless EnvFileVariable.value_types.key?(value_type)
        raise EnvFileRewrite::Invalid, "Choose secret or plain."
      end
      if dismiss && value_type != "plain"
        raise EnvFileRewrite::Invalid, "Dismiss a suggestion as plain."
      end

      store(file, name, value_type)
    end
    message_name = name.length > 80 ? "#{name.first(80)}…" : name
    dismiss ? "Dismissed the suggestion for #{message_name}." : "Marked #{message_name} as #{value_type}."
  end

  def self.store(file, name, type)
    file.variables.where(name: name).each { |row| row.store_as!(type) }
    file.pending_edits.where(name: name).each { |edit| edit.store_as!(type) }
    file.pending_choices.where(name: name).each { |choice| choice.store_as!(type) }
    file.variables.reset
    file.pending_edits.reset
    file.pending_choices.reset
  end

  def initialize(file)
    @file = file
  end

  def types
    @types ||= @file.variables.where.not(value_type: nil).pluck(:name, :value_type).to_h
  end

  def suggestions
    result = @file.parsed_contents
    return [] if @file.deleted_in_s3? || result.error

    result.entries.map(&:name).uniq.select { |name| !types.key?(name) && SecretName.match?(name) }
  end
end
