class EnvFileVariable < ApplicationRecord
  include TypedValues
  belongs_to :env_file
  enum :value_type, { secret: "secret", plain: "plain" }, validate: { allow_nil: true }
  stores_typed_values :value
end
