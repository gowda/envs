class CreatePendingEdits < ActiveRecord::Migration[8.1]
  def change
    create_table :pending_edits do |t|
      t.references :env_file, null: false, foreign_key: { on_delete: :cascade }
      t.string :name, null: false
      t.integer :occurrence, null: false
      t.text :value, null: false
      t.timestamps
      t.index [ :env_file_id, :name, :occurrence ], unique: true
    end
  end
end
