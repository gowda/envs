class EnvFileRewrite
  class Invalid < StandardError; end
  Operation = Data.define(:kind, :old_text, :new_text)
  Result = Data.define(:text, :operations)

  def self.entries(file)
    result = file.parsed_contents
    raise Invalid, result.error if result.error

    EnvFileConflicts.new(file).entries
  end

  def self.call(file, text:, edits: file.pending_edits.to_a)
    rewrite(file, text: text, edits: edits).text
  end

  def self.rewrite(file, text:, edits: file.pending_edits.to_a, check_conflicts: true)
    EnvFileConflicts.ensure_publishable!(file) if check_conflicts
    new(file, text, edits).call
  end

  def self.validate_entries!(file, edits)
    edits.each { |edit| raise Invalid, edit.errors.full_messages.join(" ") unless edit.valid? }
    values = edits.index_by(&:name)
    selected = entries(file)
    text = file.parsed_contents.entries.map do |entry|
      value = selected[entry.name] == entry && values[entry.name] ? values[entry.name].value : entry.value
      "#{entry.name}=#{value}\n"
    end.join
    result = EnvFileContents.call(text)
    raise Invalid, result.error if result.error
  end

  def initialize(file, text, edits)
    @file = file
    @text = text
    @edits = edits
  end

  def call
    entries = self.class.entries(@file)
    choices = EnvFileConflicts.new(@file).active_choices
    choices.each { |choice| validate!(choice) }
    replacements = @edits.to_h do |edit|
      validate!(edit)
      entry = entries[edit.name]
      raise Invalid, "The variable no longer exists. Refresh the file." unless entry

      [ entry.line_number, edit.value ]
    end
    chosen_names = choices.map(&:name).to_set
    removed = @file.parsed_contents.entries.select do |entry|
      chosen_names.include?(entry.name) && entries.fetch(entry.name) != entry
    end.map(&:line_number).to_set
    operations = operations_for(removed, replacements)
    text = operations.map(&:new_text).join
    validate_text!(text, removed, replacements, chosen_names)
    Result.new(text, operations)
  end

  private

  def validate!(record)
    raise Invalid, record.errors.full_messages.join(" ") unless record.valid?
  end

  def operations_for(removed, replacements)
    lines = @text.b.lines
    bom = lines.first&.start_with?("\uFEFF".b) && removed.include?(1)
    operations = lines.each_with_index.map do |line, index|
      number = index + 1
      replacement = if removed.include?(number)
        "".b
      elsif replacements.key?(number)
        ending = line[/\r\n\z|\n\z|\r\z/] || ""
        line.byteslice(0, line.index("=") + 1) + replacements.fetch(number).b + ending
      else
        line
      end
      kind = removed.include?(number) ? :remove : (replacement == line ? :keep : :change)
      Operation.new(kind, line, replacement)
    end
    if bom
      index = operations.index { |operation| operation.kind != :remove }
      operation = operations.fetch(index)
      operations[index] = Operation.new(:change, operation.old_text, "\uFEFF".b + operation.new_text)
    end
    operations
  end

  def validate_text!(text, removed, replacements, chosen_names)
    result = EnvFileContents.call(text)
    raise Invalid, result.error if result.error

    wanted = @file.parsed_contents.entries.reject { |entry| removed.include?(entry.line_number) }.map do |entry|
      [ entry.name, replacements.fetch(entry.line_number, entry.value).dup.force_encoding(Encoding::UTF_8) ]
    end
    actual = result.entries.map { |entry| [ entry.name, entry.value ] }
    counts = result.entries.map(&:name).tally
    unless actual == wanted && chosen_names.all? { |name| counts[name] == 1 }
      raise Invalid, "The edit changes another entry."
    end
  end
end
