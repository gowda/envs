class CreateUploads < ActiveRecord::Migration[8.1]
  def change
    create_table :uploads do |t|
      t.string :public_id, null: false
      t.timestamps
    end
    add_index :uploads, :public_id, unique: true
  end
end
