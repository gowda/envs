module DatabaseRows
  def raw_rows(table_name)
    table = Arel::Table.new(table_name)
    ActiveRecord::Base.connection.select_all(table.project(Arel.star)).to_a
  end
end

RSpec.configure do |config|
  config.include DatabaseRows
end
