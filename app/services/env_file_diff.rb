class EnvFileDiff
  Row = Data.define(:old_number, :new_number, :marker, :text, :kind)

  def self.call(old_text, new_text)
    old_lines = old_text.dup.force_encoding(Encoding::UTF_8).lines
    new_lines = new_text.dup.force_encoding(Encoding::UTF_8).lines
    changed = old_lines.each_index.select { |index| old_lines[index] != new_lines[index] }
    visible = changed.flat_map { |index| ([ 0, index - 3 ].max..[ old_lines.size - 1, index + 3 ].min).to_a }.uniq.sort
    previous = nil
    visible.flat_map do |index|
      rows = []
      rows << Row.new(nil, nil, "…", "", "gap") if previous && index > previous + 1
      if old_lines[index] == new_lines[index]
        rows << Row.new(index + 1, index + 1, " ", old_lines[index].chomp, "context")
      else
        rows << Row.new(index + 1, nil, "-", old_lines[index].chomp, "deletion")
        rows << Row.new(nil, index + 1, "+", new_lines[index].chomp, "addition")
      end
      previous = index
      rows
    end
  end
end
