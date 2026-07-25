Rails.application.routes.draw do
  resource :session
  resources :passwords, param: :token

  # No :show — a pantry item is only ever seen in the context of its location
  # group, and :new is the persistent quick-add form on the index (§4.1).
  resources :pantry_items, except: %i[ show new ]

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # §4.1 — "the main screen is the inventory".
  root "pantry_items#index"
end
