require "rails_helper"
require Rails.root.join("db/migrate/20261114000005_add_pending_change_bases")

RSpec.describe AddPendingChangeBases do
  include_context "legacy database"
  it "backfills encrypted bases from the chosen or last line and deletes rows for missing names" do
    migration = described_class.new
    models = [ StoreVariableRows::Snapshot, StoreVariableRows::Edit, StoreVariableRows::Choice ]
    migration.migrate(:down)
    models.each(&:reset_column_information)
    file = StoreVariableRows::Snapshot.create!(bucket: "invented-bucket", key: "invented.env",
      content: "FIRST=base\nSAME=first\nSAME=last\nFREE=earlier\nFREE=latest\n", fetched_at: Time.current)
    first = StoreVariableRows::Edit.create!(env_file_id: file.id, name: "FIRST", value: "local")
    same = StoreVariableRows::Edit.create!(env_file_id: file.id, name: "SAME", value: "local-same")
    free = StoreVariableRows::Edit.create!(env_file_id: file.id, name: "FREE", value: "local-free")
    gone = StoreVariableRows::Edit.create!(env_file_id: file.id, name: "GONE", value: "local-gone")
    choice = StoreVariableRows::Choice.create!(env_file_id: file.id, name: "SAME", keep_occurrence: 1, line_count: 2)
    StoreVariableRows::Choice.insert_all!([ { env_file_id: file.id, name: "MISSING", keep_occurrence: 1, line_count: 2 } ])

    migration.migrate(:up)
    models.each(&:reset_column_information)
    expect(first.reload.base_value).to eq("base")
    expect(same.reload.base_value).to eq("first")
    expect(free.reload.base_value).to eq("latest")
    expect(choice.reload.base_values).to eq(%w[first last])
    expect(StoreVariableRows::Edit.exists?(gone.id)).to be(false)
    expect(StoreVariableRows::Choice.pluck(:name)).to eq([ "SAME" ])
    expect(file.reload).not_to be_deleted_in_s3
    [ [ "pending_edits", "base_value" ], [ "pending_choices", "base_values" ] ].each do |table, column|
      raw = raw_rows(table).first.fetch(column)
      expect(JSON.parse(raw)).to have_key("p")
      expect(raw).not_to include("base", "first", "last")
    end
  ensure
    models&.each(&:reset_column_information)
  end
end
