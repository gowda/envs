class EnvFileEditing
  class MissingVariable < EnvFileRewrite::Invalid
    def initialize
      super("The variable no longer exists. Refresh the file.")
    end
  end

  def self.entry_for_name(file, name)
    EnvFileRewrite.entries(file)[name] || raise(MissingVariable)
  end

  def self.discard(file)
    file.with_lock { file.pending_edits.delete_all }
  end

  def self.save(file, name:, value:)
    file.with_lock do
      entry = entry_for_name(file, name)
      edit = file.pending_edits.find_or_initialize_by(name: name)
      edit.value = value
      edits = file.pending_edits.to_a.reject { |other| other.name == name }
      EnvFileRewrite.call(file, edits + [ edit ])
      if value == entry.value
        edit.destroy! if edit.persisted?
      else
        edit.save!
      end
    end
  end

  def self.reconcile(file)
    entries = file.parsed_contents.entries.index_by(&:name)
    file.pending_edits.each do |edit|
      entry = entries[edit.name]
      edit.destroy! if !entry || entry.value == edit.value
    end
  end
end
