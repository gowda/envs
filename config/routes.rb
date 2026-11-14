Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  root to: redirect("/files", status: 302)
  get "files", to: "uploads#new", as: :files
  post "files", to: "uploads#create"
  get "files/:id", to: "uploads#show", as: :file
  get "s3", to: "env_files#index", as: :s3
  post "s3/refresh", to: "env_files#refresh", as: :refresh_s3
  post "s3/:id/value_types", to: "env_files#update_value_type", as: :s3_value_types
  post "s3/:id/reveal", to: "env_files#reveal", as: :reveal_s3_file
  post "s3/:id/edits/reveal", to: "env_files#reveal_edit", as: :reveal_s3_edit
  post "s3/:id/choices/reveal", to: "env_files#reveal_choice", as: :reveal_s3_choice
  post "s3/:id/review/reveal", to: "env_files#reveal_review", as: :reveal_s3_review
  get "s3/:id/edits", to: "env_files#edit", as: :edit_s3_variable
  post "s3/:id/edits", to: "env_files#update_edit"
  delete "s3/:id/edits", to: "env_files#delete_edit"
  get "s3/:id/choices", to: "env_files#choice", as: :s3_variable_choice
  post "s3/:id/choices", to: "env_files#update_choice"
  delete "s3/:id/choices", to: "env_files#delete_choice"
  post "s3/:id/discard", to: "env_files#discard", as: :discard_s3_changes
  get "s3/:id/review", to: "env_files#review", as: :review_s3_file
  post "s3/:id/publish", to: "env_files#publish", as: :publish_s3_file
  get "s3/:id", to: "env_files#show", as: :s3_file
end
