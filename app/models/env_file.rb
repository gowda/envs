class EnvFile < ApplicationRecord
  has_many :variables, -> { order(:position) }, class_name: "EnvFileVariable", dependent: :delete_all
  serialize :unassigned_lines, coder: JSON
  has_many :pending_edits, dependent: :delete_all
  has_many :pending_choices, dependent: :delete_all

  def pending_changes?
    pending_edits.any? || pending_choices.any?
  end

  def file_name
    File.basename(key)
  end

  def parsed_contents
    error = too_large? ? EnvFileContents::TOO_LARGE_MESSAGE : parse_error
    entries = error ? [] : variables.map { |row| EnvFileContents::Entry.new(row.line_number, row.name, row.value) }
    EnvFileContents::Result.new(entries, error, unassigned_lines || [])
  end
end
