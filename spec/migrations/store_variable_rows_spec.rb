require "rails_helper"

RSpec.describe StoreVariableRows do
  include_context "legacy database"

  it "converts text and pending changes by type while keeping invalid and deleted state" do
    legacy = described_class::Snapshot
    text = "# invented-comment\nPLAIN=invented-plain\nPASSWORD=invented-first\nPASSWORD=invented-last\nUNDECIDED=invented-undecided\nBARE\n"
    file = legacy.create!(bucket: "invented-bucket", key: "invented.env", content: text,
      etag: '"old"', fetched_at: Time.current, deleted_in_s3: true)
    invalid = legacy.create!(bucket: file.bucket, key: "invalid.env", content: "A B=invalid",
      fetched_at: Time.current)
    large = legacy.create!(bucket: file.bucket, key: "large.env", too_large: true, fetched_at: Time.current)
    %w[PLAIN PASSWORD].each do |name|
      described_class::Type.create!(bucket: file.bucket, key: file.key, name: name,
        value_type: name == "PASSWORD" ? "secret" : "plain")
    end
    %w[PLAIN PASSWORD UNDECIDED].each do |name|
      described_class::Edit.create!(env_file_id: file.id, name: name, value: "local-#{name}", base_value: "base-#{name}")
      described_class::Choice.create!(env_file_id: file.id, name: name,
        keep_occurrence: 1, line_count: 2, base_values: [ "first-#{name}", "last-#{name}" ])
    end
    invalid_edit = described_class::Edit.create!(env_file_id: invalid.id, name: "GONE", value: "kept", base_value: "original")

    described_class.new.migrate(:up)
    [ EnvFile, EnvFileVariable, PendingEdit, PendingChoice ].each(&:reset_column_information)

    current = EnvFile.find(file.id)
    expect(current).to be_deleted_in_s3
    expect(current.etag).to eq('"old"')
    expect(current.unassigned_lines).to eq([ 6 ])
    expect(current.variables.pluck(:name)).to eq(%w[PLAIN PASSWORD PASSWORD UNDECIDED])
    expect(current.variables.map(&:value)).to eq(%w[invented-plain invented-first invented-last invented-undecided])
    expect(current.variables.pluck(:position, :line_number)).to eq([ [ 0, 2 ], [ 1, 3 ], [ 2, 4 ], [ 3, 5 ] ])
    %w[PLAIN PASSWORD UNDECIDED].each do |name|
      edit = current.pending_edits.find_by!(name: name)
      choice = current.pending_choices.find_by!(name: name)
      expect([ edit.value, edit.base_value ]).to eq([ "local-#{name}", "base-#{name}" ])
      expect(choice.base_values).to eq([ "first-#{name}", "last-#{name}" ])
      raw = raw_rows("pending_edits").find { |row| row["id"] == edit.id }.to_s
      name == "PASSWORD" ? expect(raw).not_to(include("local-PASSWORD", "base-PASSWORD")) : expect(raw).to(include("local-#{name}", "base-#{name}"))
      raw_choice = raw_rows("pending_choices").find { |row| row["id"] == choice.id }.fetch("base_values")
      name == "PASSWORD" ? expect(raw_choice).not_to(include("first-PASSWORD")) : expect(raw_choice).to(include("first-#{name}"))
    end
    expect(EnvFile.find(invalid.id).parse_error).to include("space")
    expect(EnvFile.find(large.id)).to be_too_large
    expect(PendingEdit.find(invalid_edit.id).value).to eq("kept")
    expect(ActiveRecord::Base.connection.table_exists?(:variable_types)).to be(false)
    expect(EnvFile.column_names).not_to include("content")
    rows = raw_rows("env_file_variables").to_s
    expect(rows).to include("invented-plain", "invented-undecided")
    expect(rows).not_to include("invented-first", "invented-last", "invented-comment", "BARE")
  end
end
