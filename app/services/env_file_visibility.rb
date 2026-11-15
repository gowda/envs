class EnvFileVisibility
  MASK = "••••••••"

  def initialize(file, revealed_name: nil)
    @types = EnvFileValueTypes.new(file).types
    @revealed_name = revealed_name
  end

  def secret?(name)
    @types[name] == "secret"
  end

  def revealed?(name)
    secret?(name) && name == @revealed_name
  end

  def value(name, value)
    secret?(name) && !revealed?(name) ? MASK : value
  end

  def line_name(text)
    EnvFileContents.call(text).entries.first&.name
  end

  def line(text)
    name = line_name(text)
    return text unless secret?(name) && !revealed?(name)

    "#{text.partition("=").first}=#{MASK}"
  end
end
