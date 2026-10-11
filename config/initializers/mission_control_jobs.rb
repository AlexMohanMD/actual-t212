# Configure Mission Control Jobs

Rails.application.configure do
  MissionControl::Jobs.http_basic_auth_user = ENV["MISSION_CONTROL_USER"].presence || ENV["MISSION_CONTROL_USERNAME"].presence
  MissionControl::Jobs.http_basic_auth_password = ENV["MISSION_CONTROL_PASSWORD"].presence

  # Enable basic auth only if credentials are provided in the environment
  MissionControl::Jobs.http_basic_auth_enabled = MissionControl::Jobs.http_basic_auth_user.present? && MissionControl::Jobs.http_basic_auth_password.present?
end
