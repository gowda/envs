require "rails_helper"
require "open3"

RSpec.describe "Development logging" do
  it "disables query log tags so SQL values can be filtered" do
    output, error, status = Open3.capture3(
      { "RAILS_ENV" => "development" }, RbConfig.ruby, "bin/rails", "runner",
      "puts Rails.application.config.active_record.query_log_tags_enabled.inspect")

    expect(status.success?).to be(true), error
    expect(output.strip).to eq("false")
  end
end
