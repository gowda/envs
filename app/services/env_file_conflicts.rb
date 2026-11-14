class EnvFileConflicts
  Conflict = Data.define(:name, :kind)

  def initialize(file)
    @result = file.parsed_contents
    @groups = @result.entries.group_by(&:name)
    @choices = file.pending_choices.to_a
    @edits = file.pending_edits.to_a
  end

  def choice_conflict?(choice)
    !@result.error && (@groups.fetch(choice.name, []).map(&:value) != choice.base_values)
  end

  def active_choices
    @choices.reject { |choice| choice_conflict?(choice) }
  end

  def entries
    choices = active_choices.index_by(&:name)
    @groups.transform_values do |entries|
      choices[entries.last.name]&.kept_entry(entries) || entries.last
    end
  end

  def edit_conflict?(edit)
    return false if @result.error

    entry = entries[edit.name]
    !entry || (entry.value != edit.base_value && entry.value != edit.value)
  end

  def all
    return [] if @result.error

    choices = @choices.select { |choice| choice_conflict?(choice) }.map do |choice|
      Conflict.new(choice.name, @groups.fetch(choice.name, []).many? ? :lines_changed : :not_repeated)
    end
    edits = @edits.select { |edit| edit_conflict?(edit) }.map do |edit|
      Conflict.new(edit.name, @groups.key?(edit.name) ? :value_changed : :name_gone)
    end
    choices + edits
  end

  def any?
    all.any?
  end

  def self.ensure_present!(file)
    raise EnvFileRewrite::Invalid, "This file is no longer in S3." if file.deleted_in_s3?
  end

  def self.ensure_publishable!(file)
    ensure_present!(file)
    raise EnvFileRewrite::Invalid, "Resolve the conflicts before you publish." if new(file).any?
  end
end
