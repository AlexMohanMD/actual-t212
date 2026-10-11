Rails.application.routes.draw do
  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  get "up" => "rails/health#show", as: :rails_health_check

  # Mission Control Jobs dashboard as the UI
  mount MissionControl::Jobs::Engine, at: "/jobs"
  root to: redirect("/jobs")
end
