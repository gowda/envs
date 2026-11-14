require Rails.root.join("db/migrate/20261115000000_store_variable_rows")

RSpec.shared_context "legacy database" do
  self.use_transactional_tests = false

  around do |example|
    original = ActiveRecord::Base.connection_db_config.configuration_hash
    Dir.mktmpdir("migration-", Rails.root.join("tmp")) do |directory|
      ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: File.join(directory, "test.sqlite3"))
      ActiveRecord::MigrationContext.new(Rails.root.join("db/migrate")).migrate(20261114000006)
      example.run
    ensure
      ActiveRecord::Base.establish_connection(original)
      ActiveRecord::Base.descendants.each(&:reset_column_information)
    end
  end
end
