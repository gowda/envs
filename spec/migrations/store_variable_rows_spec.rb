require "rails_helper"

RSpec.describe StoreVariableRows do
  include_context "legacy database"

  it "converts text and pending changes by type while keeping invalid and deleted state" do
    original_logger = ActiveRecord::Base.logger
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
    second = legacy.create!(bucket: file.bucket, key: "second.env", content: "UNTYPED=invented-second\n", fetched_at: Time.current)
    second_edit = described_class::Edit.create!(env_file_id: second.id, name: "UNTYPED", value: "invented-second-local", base_value: "invented-second")

    output = StringIO.new
    logger = ActiveSupport::Logger.new(output)
    logger.level = Logger::DEBUG
    ActiveRecord::Base.logger = logger
    ActiveRecord::Base.connection.unprepared_statement do
      ActiveRecord::MigrationContext.new(Rails.root.join("db/migrate")).migrate(20261115000000)
    end
    [ EnvFile, EnvFileVariable, PendingEdit, PendingChoice ].each(&:reset_column_information)

    expect(EnvFileVariable.count).to eq(5)
    expect(PendingEdit.count).to eq(5)
    expect(PendingChoice.count).to eq(3)
    %i[env_file_variables pending_edits pending_choices].each do |table|
      key = ActiveRecord::Base.connection.foreign_keys(table).find { |key| key.to_table == "env_files" }
      expect(key.options[:on_delete]).to eq(:cascade)
    end
    current = EnvFile.find(file.id)
    expect(current).to be_deleted_in_s3
    expect(current.etag).to eq('"old"')
    expect(current.unassigned_lines).to eq([ 6 ])
    expect(current.variables.pluck(:name)).to eq(%w[PLAIN PASSWORD PASSWORD UNDECIDED])
    expect(current.variables.map(&:value)).to eq(%w[invented-plain invented-first invented-last invented-undecided])
    expect(current.variables.pluck(:value_type)).to eq([ "plain", "secret", "secret", nil ])
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
    expect(EnvFile.find(second.id).variables.sole.value_type).to be_nil
    expect(PendingEdit.find(second_edit.id).then { |edit| [ edit.value_type, edit.value, edit.base_value ] })
      .to eq([ nil, "invented-second-local", "invented-second" ])
    expect(ActiveRecord::Base.connection.table_exists?(:variable_types)).to be(false)
    expect(EnvFile.column_names).not_to include("content")
    rows = raw_rows("env_file_variables").to_s
    expect(rows).to include("invented-plain", "invented-undecided")
    expect(rows).not_to include("invented-first", "invented-last", "invented-comment", "BARE")
    expect(output.string).to include("env_file_variables")
    expect(output.string).not_to include("invented-plain", "invented-first", "invented-last", "invented-undecided",
      "local-PLAIN", "base-PLAIN", "local-PASSWORD", "base-PASSWORD", "local-UNDECIDED", "base-UNDECIDED",
      "first-PLAIN", "last-PLAIN", "first-PASSWORD", "last-PASSWORD", "first-UNDECIDED", "last-UNDECIDED",
      "kept", "original", "invented-second", "invented-second-local")
  ensure
    ActiveRecord::Base.logger = original_logger
  end

  it "rolls back the conversion when a data step fails" do
    file = described_class::Snapshot.create!(bucket: "invented-bucket", key: "invented.env",
      content: "FIRST=invented-first\nFIRST=invented-last\n", fetched_at: Time.current)
    described_class::Edit.create!(env_file_id: file.id, name: "FIRST", value: "invented-local", base_value: "invented-last")
    described_class::Choice.create!(env_file_id: file.id, name: "FIRST", keep_occurrence: 1, line_count: 2,
      base_values: %w[invented-first invented-last])
    described_class::Snapshot.create!(bucket: file.bucket, key: "failure.env", content: "FAIL=invented-failure\n", fetched_at: Time.current)
    tables = %w[env_files pending_edits pending_choices variable_types]
    before = tables.to_h { |table| [ table, raw_rows(table) ] }
    allow(EnvFileContents).to receive(:call).and_call_original
    allow(EnvFileContents).to receive(:call).with("FAIL=invented-failure\n").and_raise("invented conversion failure")
    context = ActiveRecord::MigrationContext.new(Rails.root.join("db/migrate"))

    expect { context.migrate(20261115000000) }.to raise_error(StandardError, /invented conversion failure/)

    tables.each { |table| expect(raw_rows(table)).to eq(before.fetch(table)) }
    expect(ActiveRecord::Base.connection.table_exists?(:env_file_variables)).to be(false)
    expect(context.get_all_versions).not_to include(20261115000000)
  end
end
