class CreateVariableTypes < ActiveRecord::Migration[8.1]
  def change
    create_table :variable_types do |t|
      t.string :bucket, null: false
      t.string :key, null: false
      t.string :name, null: false
      t.string :value_type, null: false
      t.index [ :bucket, :key, :name ], unique: true
      t.check_constraint "value_type IN ('secret', 'plain')", name: "variable_types_value_type"
    end
  end
end
