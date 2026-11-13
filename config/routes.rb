Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  root to: redirect("/files")
  get "files", to: "uploads#new", as: :files
  post "files", to: "uploads#create"
  get "files/:id", to: "uploads#show", as: :file
  get "s3", to: "env_files#index", as: :s3
  post "s3/refresh", to: "env_files#refresh", as: :refresh_s3
  get "s3/:id", to: "env_files#show", as: :s3_file
end
