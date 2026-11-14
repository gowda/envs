class EnvFileRewrite
  class Invalid < StandardError; end

  def self.entries(file)
    result = file.parsed_contents
    raise Invalid, result.error if result.error

    result.entries.index_by(&:name)
  end

  def self.call(file, edits = file.pending_edits.to_a)
    entries = entries(file)
    expected = {}
    lines = file.content.to_s.b.lines
    edits.each do |edit|
      raise Invalid, edit.errors.full_messages.join(" ") unless edit.valid?

      entry = entries[edit.name]
      raise Invalid, "The variable no longer exists. Refresh the file." unless entry

      line = lines.fetch(entry.line_number - 1)
      ending = line[/\r\n\z|\n\z|\r\z/] || ""
      lines[entry.line_number - 1] = line.byteslice(0, line.index("=") + 1) + edit.value.b + ending
      expected[entry.line_number] = edit.value.dup.force_encoding(Encoding::UTF_8)
    end
    text = lines.join
    result = EnvFileContents.call(text)
    raise Invalid, result.error if result.error

    wanted = file.parsed_contents.entries.map do |entry|
      EnvFileContents::Entry.new(entry.line_number, entry.name, expected.fetch(entry.line_number, entry.value))
    end
    raise Invalid, "The edit changes another entry." unless result.entries == wanted

    text
  end
end
