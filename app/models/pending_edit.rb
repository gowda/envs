class PendingEdit < ApplicationRecord
  belongs_to :env_file
  encrypts :value

  validates :name, presence: true, uniqueness: { scope: :env_file_id }
  validate :single_utf8_line

  private

  def single_utf8_line
    text = value.to_s.dup.force_encoding(Encoding::UTF_8)
    if !text.valid_encoding?
      errors.add(:value, "must use valid UTF-8.")
    elsif text.include?("\r") || text.include?("\n")
      errors.add(:value, "must not contain CR or LF.")
    end
  end
end
