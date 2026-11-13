class DotenvUpload
  MAX_BYTES = 1.megabyte
  INVALID_MESSAGE = "Upload a valid dotenv file with at least one variable."
  Result = Data.define(:variables, :error)

  class LiteralParser < Dotenv::Parser
    @substitutions = [].freeze
  end
  private_constant :LiteralParser

  def self.call(text)
    return Result.new(nil, "The file must be 1 MB or smaller.") if text.bytesize > MAX_BYTES

    text = text.dup.force_encoding(Encoding::UTF_8)
    return Result.new(nil, "The file must use valid UTF-8 encoding.") unless text.valid_encoding?

    text = text.gsub(/\r\n?/, "\n")
    remainder = text.gsub(Dotenv::Parser::LINE) do
      value = Regexp.last_match[:value].to_s.strip
      if value.start_with?("\"", "'") && !value.match?(/\A"(?:\\"|[^"])*"\z/) && !value.match?(/\A'(?:\\'|[^'])*'\z/)
        return Result.new(nil, INVALID_MESSAGE)
      end
      ""
    end
    return Result.new(nil, INVALID_MESSAGE) unless remainder.each_line.all? { |line| line.strip.empty? || line.lstrip.start_with?("#") }

    variables = LiteralParser.call(text, overwrite: true)
    return Result.new(nil, INVALID_MESSAGE) if variables.empty?

    Result.new(variables, nil)
  rescue Dotenv::FormatError
    Result.new(nil, INVALID_MESSAGE)
  end
end
