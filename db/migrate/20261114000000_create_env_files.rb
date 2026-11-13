class CreateEnvFiles < ActiveRecord::Migration[8.1]
  def change
    create_table :env_files do |t|
      t.string :bucket, null: false
      t.string :key, null: false
      t.string :etag
      t.datetime :last_modified
      t.datetime :fetched_at, null: false
      t.text :content
      t.boolean :too_large, null: false, default: false

      t.index [ :bucket, :key ], unique: true
    end
  end
end
