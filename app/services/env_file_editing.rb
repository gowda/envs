class EnvFileEditing
  class MissingVariable < EnvFileRewrite::Invalid
    def initialize
      super("The variable no longer exists. Refresh the file.")
    end
  end

  class StaleSnapshot < EnvFileRewrite::Invalid
    def initialize
      super("The file changed in S3. Check the value and save again.")
    end
  end

  def self.entry_for_name(file, name)
    EnvFileConflicts.ensure_present!(file)
    EnvFileRewrite.entries(file)[name] || raise(MissingVariable)
  end

  def self.discard(file)
    file.with_lock do
      file.pending_edits.delete_all
      file.pending_choices.delete_all
      file.destroy! if file.deleted_in_s3?
    end
  end

  def self.delete(file, name:)
    file.with_lock do
      EnvFileConflicts.ensure_present!(file)
      file.pending_edits.where(name: name).delete_all
    end
  end

  def self.save(file, name:, value:, etag:)
    file.with_lock do
      EnvFileConflicts.ensure_present!(file)
      raise StaleSnapshot if file.etag != etag

      entry = entry_for_name(file, name)
      edit = file.pending_edits.find_or_initialize_by(name: name)
      edit.value_type = file.variables.find_by!(name: name).value_type
      raise EnvFileRewrite::Invalid, "Type a value." if edit.secret? && value.empty?

      edit.assign_attributes(value: value, base_value: entry.value)
      entries = EnvFileRewrite.entries(file)
      edits = file.pending_edits.to_a.reject { |other| other.name == name || !entries.key?(other.name) }
      EnvFileRewrite.validate_entries!(file, edits + [ edit ])
      if value == entry.value
        edit.destroy! if edit.persisted?
      else
        edit.save!
      end
    end
  end

  def self.reconcile(file)
    return if file.parsed_contents.error

    entries = EnvFileRewrite.entries(file)
    file.pending_edits.each do |edit|
      edit.destroy! if entries[edit.name]&.value == edit.value
    end
    file.pending_edits.reset
  end
end
