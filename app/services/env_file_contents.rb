class EnvFileContents
  MAX_BYTES = 1.megabyte
  MAX_LINE_BYTES = 65_536
  TOO_LARGE_MESSAGE = "The file must be 1 MB or smaller."
  INVALID_MESSAGE = "The env file must contain at least one entry with =."
  Entry = Data.define(:line_number, :name, :value)
  Result = Data.define(:entries, :error, :unassigned_lines)

  def self.call(text)
    return Result.new([], TOO_LARGE_MESSAGE, []) if text.bytesize > MAX_BYTES

    entries = []
    unassigned_lines = []
    text = text.dup.force_encoding(Encoding::UTF_8)
    text.each_line.with_index(1) do |line, number|
      reason = if !line.valid_encoding?
        "the line must use valid UTF-8 encoding."
      elsif line.chomp.bytesize > MAX_LINE_BYTES
        "the line exceeds 65,536 bytes."
      end
      return Result.new([], "Line #{number}: #{reason}", []) if reason

      line = line.chomp.delete_prefix(number == 1 ? "\uFEFF" : "")
      line = line.sub(/\A[[:space:]]+/, "")
      next if line.empty? || line.start_with?("#")

      name, separator, value = line.partition("=")
      if separator.empty?
        unassigned_lines << number
        next
      end

      reason = if name.empty?
        "the name before = is empty."
      elsif name.include?(" ")
        "the name holds a space."
      elsif name.include?("\t")
        "the name holds a tab."
      end
      return Result.new([], "Line #{number}: #{reason}", []) if reason

      entries << Entry.new(number, name, value)
    end
    Result.new(entries, entries.empty? ? INVALID_MESSAGE : nil, unassigned_lines)
  end
end
