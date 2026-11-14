class VariableType < ApplicationRecord
  enum :value_type, { secret: "secret", plain: "plain" }, validate: true
  validates :bucket, :key, :name, presence: true
  validates :name, uniqueness: { scope: [ :bucket, :key ] }
end
