class Upload < ApplicationRecord
  has_secure_token :public_id
  has_one_attached :file

  def to_param
    public_id
  end
end
