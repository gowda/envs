class StoreVariableRows < ActiveRecord::Migration[8.1]
  class Snapshot < ActiveRecord::Base
    self.table_name = "env_files"
    encrypts :content
  end

  class Type < ActiveRecord::Base
    self.table_name = "variable_types"
  end

  class Variable < ActiveRecord::Base
    self.table_name = "env_file_variables"
    self.filter_attributes += [ :value ]
  end

  class Edit < ActiveRecord::Base
    self.table_name = "pending_edits"
    encrypts :value, :base_value
  end

  class Choice < ActiveRecord::Base
    self.table_name = "pending_choices"
    serialize :base_values, coder: JSON
    encrypts :base_values
  end

  class PlainEdit < ActiveRecord::Base
    self.table_name = "pending_edits"
    self.filter_attributes += [ :value, :base_value ]
  end

  class PlainChoice < ActiveRecord::Base
    self.table_name = "pending_choices"
    self.filter_attributes += [ :base_values ]
  end

  def up
    create_table :env_file_variables do |t|
      t.references :env_file, null: false, foreign_key: { on_delete: :cascade }
      t.integer :position, null: false
      t.integer :line_number, null: false
      t.string :name, null: false
      t.text :value, null: false
      t.string :value_type
      t.index [ :env_file_id, :position ], unique: true
      t.index [ :env_file_id, :name ]
    end
    add_column :env_files, :parse_error, :text
    add_column :env_files, :unassigned_lines, :text
    [ :pending_edits, :pending_choices ].each do |table|
      add_column table, :value_type, :string
    end
    [ Snapshot, Variable, Edit, Choice, PlainEdit, PlainChoice ].each(&:reset_column_information)
    Snapshot.find_each do |file|
      types = Type.where(bucket: file.bucket, key: file.key).pluck(:name, :value_type).to_h
      result = file.too_large? ? EnvFileContents::Result.new([], EnvFileContents::TOO_LARGE_MESSAGE, []) : EnvFileContents.call(file.content.to_s)
      file.update_columns(parse_error: result.error, unassigned_lines: JSON.generate(result.unassigned_lines))
      result.entries.each_with_index do |entry, position|
        type = types[entry.name]
        Variable.create!(env_file_id: file.id, position: position, line_number: entry.line_number,
          name: entry.name, value_type: type, value: stored(entry.value, type))
      end
      Edit.where(env_file_id: file.id).each do |edit|
        type = types[edit.name]
        if type == "secret"
          edit.update_columns(value_type: type, value: edit.value, base_value: edit.base_value)
        else
          values = { value_type: type, value: edit.value, base_value: edit.base_value }
          write_plain(Edit, edit.id, values)
        end
      end
      Choice.where(env_file_id: file.id).each do |choice|
        type = types[choice.name]
        if type == "secret"
          choice.update_columns(value_type: type, base_values: choice.base_values)
        else
          write_plain(Choice, choice.id, value_type: type, base_values: choice.base_values && JSON.generate(choice.base_values))
        end
      end
    end
    remove_column :env_files, :content
    drop_table :variable_types
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "The object text is held only in S3."
  end

  private

  def stored(value, type)
    type == "secret" ? ActiveRecord::Encryption.encryptor.encrypt(value) : value
  end

  def write_plain(model, id, values)
    plain = model == Edit ? PlainEdit : PlainChoice
    plain.where(id: id).update_all(values)
  end
end
