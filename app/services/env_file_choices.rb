class EnvFileChoices
  def self.entries(file, name, line_count: nil)
    result = file.parsed_contents
    raise EnvFileRewrite::Invalid, result.error if result.error

    entries = result.entries.select { |entry| entry.name == name }
    if line_count && entries.size.to_s != line_count.to_s
      raise EnvFileRewrite::Invalid, "The lines changed. Refresh the file."
    end
    raise EnvFileRewrite::Invalid, "The name is not repeated." unless entries.many?

    entries
  end

  def self.save(file, name:, line_number:, line_count:)
    file.with_lock do
      entries = entries(file, name, line_count: line_count.to_s)

      occurrence = entries.index { |entry| entry.line_number.to_s == line_number.to_s }
      raise EnvFileRewrite::Invalid, "Select a line to keep." unless occurrence

      choice = file.pending_choices.find_or_initialize_by(name: name)
      choice.update!(keep_occurrence: occurrence + 1, line_count: entries.size)
      EnvFileEditing.reconcile(file)
    end
  end

  def self.delete(file, name:)
    file.with_lock do
      file.pending_choices.where(name: name).delete_all
      EnvFileEditing.reconcile(file)
    end
  end
end
