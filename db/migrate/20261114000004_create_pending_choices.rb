class CreatePendingChoices < ActiveRecord::Migration[8.1]
  def change
    create_table :pending_choices do |t|
      t.references :env_file, null: false, foreign_key: { on_delete: :cascade }
      t.string :name, null: false
      t.integer :keep_occurrence, null: false
      t.integer :line_count, null: false
      t.timestamps
    end
    add_index :pending_choices, [ :env_file_id, :name ], unique: true
  end
end
