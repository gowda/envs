class PendingChoice < ApplicationRecord
  belongs_to :env_file

  validates :name, presence: true, uniqueness: { scope: :env_file_id }
  validates :keep_occurrence, numericality: { only_integer: true, greater_than: 0 }
  validates :line_count, numericality: { only_integer: true, greater_than: 1 }
  validate :matches_snapshot

  def kept_entry(entries)
    entries[keep_occurrence - 1]
  end

  private

  def matches_snapshot
    result = env_file.parsed_contents
    entries = result.entries.select { |entry| entry.name == name }
    if result.error || entries.size != line_count || !keep_occurrence&.between?(1, entries.size)
      errors.add(:base, "The lines changed. Refresh the file.")
    end
  end
end
