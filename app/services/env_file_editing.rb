class EnvFileEditing
  def self.entry_for_line(file, line_number)
    pair = EnvFileRewrite.entries(file).find { |_identity, entry| entry.line_number.to_s == line_number.to_s }
    raise ActiveRecord::RecordNotFound unless pair

    pair
  end

  def self.discard(file)
    file.with_lock { file.pending_edits.delete_all }
  end

  def self.save(file, name:, occurrence:, value:)
    file.with_lock do
      entry = EnvFileRewrite.entries(file)[[ name, occurrence ]]
      raise EnvFileRewrite::Invalid, "The occurrence no longer exists. Refresh the file." unless entry

      edit = file.pending_edits.find_or_initialize_by(name: name, occurrence: occurrence)
      edit.value = value
      edits = file.pending_edits.to_a.reject { |other| other.name == name && other.occurrence == occurrence }
      EnvFileRewrite.call(file, edits + [ edit ])
      if value == entry.value
        edit.destroy! if edit.persisted?
      else
        edit.save!
      end
    end
  end

  def self.reconcile(file)
    counts = Hash.new(0)
    entries = file.parsed_contents.entries.to_h do |entry|
      counts[entry.name] += 1
      [ [ entry.name, counts[entry.name] ], entry.value ]
    end
    file.pending_edits.each do |edit|
      identity = [ edit.name, edit.occurrence ]
      edit.destroy! if !entries.key?(identity) || entries[identity] == edit.value
    end
  end
end
