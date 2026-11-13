Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  root "env_files#index"
  post "refresh", to: "env_files#refresh", as: :refresh_env_files
  resources :env_files, only: :show
  get "upload", to: "uploads#new", as: :upload
  post "upload", to: "uploads#create"
end
