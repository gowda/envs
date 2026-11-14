class SecretName
  WORDS = %w[PASSWORD PASSWD PASS PWD SECRET TOKEN KEY CREDENTIAL CREDENTIALS PRIVATE].freeze

  def self.match?(name)
    name.split(/[_\-.]/).any? { |word| WORDS.include?(word.upcase) }
  end
end
