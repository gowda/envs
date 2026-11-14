module TypedValues
  extend ActiveSupport::Concern

  class_methods do
    def stores_typed_values(*columns, json: false)
      self.filter_attributes += columns
      define_method("value_type=") do |type|
        values = columns.to_h { |column| [ column, public_send(column) ] }
        super(type)
        assign_attributes(values)
      end
      columns.each do |column|
        define_method(column) do
          raw = self[column]
          if raw && value_type == "secret"
            ActiveRecord::Encryption.config.primary_key
            raw = ActiveRecord::Encryption.encryptor.decrypt(raw)
          end
          json && raw ? JSON.parse(raw) : raw
        end
        define_method("#{column}=") do |value|
          raw = json && !value.nil? ? JSON.generate(value) : value
          if raw && value_type == "secret"
            ActiveRecord::Encryption.config.primary_key
            raw = ActiveRecord::Encryption.encryptor.encrypt(raw)
          end
          self[column] = raw
        end
      end
    end
  end

  def store_as!(type)
    self.value_type = type
    save!(validate: false)
  end
end
