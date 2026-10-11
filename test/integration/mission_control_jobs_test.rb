require "test_helper"

class MissionControlJobsTest < ActionDispatch::IntegrationTest
  test "root redirects to /jobs" do
    get "/"
    assert_response :redirect
    assert_redirected_to "/jobs"

    follow_redirect!
    assert_response :success
    assert_includes response.body, "Mission control"
  end

  test "can access mission control jobs dashboard directly" do
    get "/jobs"
    assert_response :success
    assert_includes response.body, "Mission control"
  end

  test "basic authentication can be enabled via credentials" do
    original_user = MissionControl::Jobs.http_basic_auth_user
    original_pass = MissionControl::Jobs.http_basic_auth_password
    original_enabled = MissionControl::Jobs.http_basic_auth_enabled

    begin
      MissionControl::Jobs.http_basic_auth_user = "admin"
      MissionControl::Jobs.http_basic_auth_password = "secretpassword"
      MissionControl::Jobs.http_basic_auth_enabled = true

      get "/jobs"
      assert_response :unauthorized

      encoded_credentials = ActionController::HttpAuthentication::Basic.encode_credentials("admin", "secretpassword")
      get "/jobs", headers: { "HTTP_AUTHORIZATION" => encoded_credentials }
      assert_response :success
    ensure
      MissionControl::Jobs.http_basic_auth_user = original_user
      MissionControl::Jobs.http_basic_auth_password = original_pass
      MissionControl::Jobs.http_basic_auth_enabled = original_enabled
    end
  end
end
