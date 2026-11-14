class AddPendingChangeBases < ActiveRecord::Migration[8.1]
  class Snapshot < ActiveRecord::Base
    self.table_name = "env_files"
    encrypts :content
  end

  class Edit < ActiveRecord::Base
    self.table_name = "pending_edits"
    encrypts :base_value
  end

  class Choice < ActiveRecord::Base
    self.table_name = "pending_choices"
    serialize :base_values, coder: JSON
    encrypts :base_values
  end

  def up
    add_column :env_files, :deleted_in_s3, :boolean, null: false, default: false
    add_column :pending_edits, :base_value, :text
    add_column :pending_choices, :base_values, :text
    Edit.reset_column_information
    Choice.reset_column_information
    Snapshot.find_each do |file|
      groups = EnvFileContents.call(file.content.to_s).entries.group_by(&:name)
      choices = Choice.where(env_file_id: file.id)
      choices.each do |choice|
        entries = groups[choice.name]
        entries ? choice.update!(base_values: entries.map(&:value)) : choice.destroy!
      end
      choices = choices.reload.index_by(&:name)
      Edit.where(env_file_id: file.id).each do |edit|
        entries = groups[edit.name]
        if entries
          choice = choices[edit.name]
          entry = choice && entries[choice.keep_occurrence - 1]
          edit.update!(base_value: (entry || entries.last).value)
        else
          edit.destroy!
        end
      end
    end
  end

  def down
    remove_column :pending_choices, :base_values
    remove_column :pending_edits, :base_value
    remove_column :env_files, :deleted_in_s3
  end
end
