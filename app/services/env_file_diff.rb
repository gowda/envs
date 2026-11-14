class EnvFileDiff
  Row = Data.define(:old_number, :new_number, :marker, :text, :kind)

  def self.call(operations)
    changed = operations.each_index.select { |index| operations[index].kind != :keep }
    visible = changed.flat_map { |index| ([ 0, index - 3 ].max..[ operations.size - 1, index + 3 ].min).to_a }.to_set
    previous = nil
    new_number = 0
    operations.each_with_index.flat_map do |operation, index|
      new_number += 1 unless operation.kind == :remove
      next [] unless visible.include?(index)

      rows = []
      rows << Row.new(nil, nil, "…", "", "gap") if previous && index > previous + 1
      if operation.kind == :keep
        rows << Row.new(index + 1, new_number, " ", display(operation.old_text), "context")
      else
        rows << Row.new(index + 1, nil, "-", display(operation.old_text), "deletion")
        rows << Row.new(nil, new_number, "+", display(operation.new_text), "addition") unless operation.kind == :remove
      end
      previous = index
      rows
    end
  end

  def self.display(text)
    text.dup.force_encoding(Encoding::UTF_8).chomp
  end
end
