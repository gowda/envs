require "rails_helper"
require Rails.root.join("db/migrate/20261114000005_add_pending_change_bases")

RSpec.describe AddPendingChangeBases do
  it "backfills encrypted bases from the chosen or last line and deletes rows for missing names" do
    migration = described_class.new
    models = [ EnvFile, PendingEdit, PendingChoice ]
    migration.migrate(:down)
    models.each(&:reset_column_information)
    file = EnvFile.create!(bucket: "invented-bucket", key: "invented.env",
      content: "FIRST=base\nSAME=first\nSAME=last\nFREE=earlier\nFREE=latest\n", fetched_at: Time.current)
    first = PendingEdit.create!(env_file: file, name: "FIRST", value: "local")
    same = PendingEdit.create!(env_file: file, name: "SAME", value: "local-same")
    free = PendingEdit.create!(env_file: file, name: "FREE", value: "local-free")
    gone = PendingEdit.create!(env_file: file, name: "GONE", value: "local-gone")
    choice = PendingChoice.create!(env_file: file, name: "SAME", keep_occurrence: 1, line_count: 2)
    PendingChoice.insert_all!([ { env_file_id: file.id, name: "MISSING", keep_occurrence: 1, line_count: 2 } ])

    migration.migrate(:up)
    models.each(&:reset_column_information)
    expect(first.reload.base_value).to eq("base")
    expect(same.reload.base_value).to eq("first")
    expect(free.reload.base_value).to eq("latest")
    expect(choice.reload.base_values).to eq(%w[first last])
    expect(PendingEdit.exists?(gone.id)).to be(false)
    expect(PendingChoice.pluck(:name)).to eq([ "SAME" ])
    expect(file.reload).not_to be_deleted_in_s3
    [ [ "pending_edits", "base_value" ], [ "pending_choices", "base_values" ] ].each do |table, column|
      raw = ActiveRecord::Base.connection.select_value("SELECT #{column} FROM #{table}")
      expect(JSON.parse(raw)).to have_key("p")
      expect(raw).not_to include("base", "first", "last")
    end
  ensure
    models&.each(&:reset_column_information)
  end
end
