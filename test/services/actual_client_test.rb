require "test_helper"

class ActualClientTest < ActiveSupport::TestCase
  setup do
    Transaction.delete_all
    @client = ActualClient.new(
      base_url: "https://api.actual.int.alexmmd.com",
      api_key: "test-api-key",
      budget_sync_id: "test-budget-sync-id",
      account_id: "test-account-id"
    )
  end

  test "amount_in_minor_units converts currency properly" do
    assert_equal 1050, @client.amount_in_minor_units(BigDecimal("10.50"))
    assert_equal(-399, @client.amount_in_minor_units(BigDecimal("-3.99")))
    assert_equal 0, @client.amount_in_minor_units(0)
    assert_equal 0, @client.amount_in_minor_units(nil)
    assert_equal 100, @client.amount_in_minor_units(1.0)
  end

  test "format_date produces YYYY-MM-DD strings" do
    time = Time.utc(2026, 10, 11, 14, 30, 0)
    assert_equal "2026-10-11", @client.format_date(time)
    assert_equal "2026-05-01", @client.format_date("2026-05-01")
  end

  test "endpoint_url constructs clean URLs with v1 prefix" do
    client1 = ActualClient.new(base_url: "https://api.actual.int.alexmmd.com")
    assert_equal "https://api.actual.int.alexmmd.com/v1/budgets/sync-123/accounts",
                 client1.endpoint_url("/budgets/sync-123/accounts")

    client2 = ActualClient.new(base_url: "https://api.actual.int.alexmmd.com/v1")
    assert_equal "https://api.actual.int.alexmmd.com/v1/budgets/sync-123/accounts",
                 client2.endpoint_url("/budgets/sync-123/accounts")

    client3 = ActualClient.new(base_url: "https://api.actual.int.alexmmd.com/")
    assert_equal "https://api.actual.int.alexmmd.com/v1/actualhttpapiversion",
                 client3.endpoint_url("actualhttpapiversion")
  end

  test "format_transaction builds the expected payload hash" do
    tx = Transaction.create!(
      payee: "Sainsbury's",
      notes: "Groceries",
      amount: -45.50,
      occurred_at: Time.utc(2026, 10, 10, 12, 0, 0),
      synced_to_actual: false
    )

    formatted = @client.format_transaction(tx)
    assert_equal "test-account-id", formatted[:account]
    assert_equal "2026-10-10", formatted[:date]
    assert_equal(-4550, formatted[:amount])
    assert_equal "Sainsbury's", formatted[:payee_name]
    assert_equal "Groceries", formatted[:notes]
    assert_equal "t212-#{tx.id}", formatted[:imported_id]
    assert_equal true, formatted[:cleared]
  end

  test "validation raises ConfigurationError when credentials are missing" do
    orig_key = ENV["ACTUAL_API_KEY"]
    orig_budget = ENV["ACTUAL_BUDGET_SYNC_ID"]
    orig_acc = ENV["ACTUAL_ACCOUNT_ID"]
    orig_acc_name = ENV["ACTUAL_ACCOUNT_NAME"]

    begin
      ENV["ACTUAL_API_KEY"] = nil
      ENV["ACTUAL_BUDGET_SYNC_ID"] = nil
      ENV["ACTUAL_ACCOUNT_ID"] = nil
      ENV["ACTUAL_ACCOUNT_NAME"] = nil

      client_no_key = ActualClient.new(base_url: "http://localhost", api_key: nil, budget_sync_id: "id", account_id: "acc")
      assert_raises(ActualClient::ConfigurationError) { client_no_key.validate_credentials! }

      client_no_budget = ActualClient.new(base_url: "http://localhost", api_key: "k", budget_sync_id: nil, account_id: "acc")
      assert_raises(ActualClient::ConfigurationError) { client_no_budget.validate_credentials! }

      client_no_acc = ActualClient.new(base_url: "http://localhost", api_key: "k", budget_sync_id: "b", account_id: nil)
      assert_raises(ActualClient::ConfigurationError) { client_no_acc.validate_credentials! }
    ensure
      ENV["ACTUAL_API_KEY"] = orig_key
      ENV["ACTUAL_BUDGET_SYNC_ID"] = orig_budget
      ENV["ACTUAL_ACCOUNT_ID"] = orig_acc
      ENV["ACTUAL_ACCOUNT_NAME"] = orig_acc_name
    end
  end

  test "sync_unsynced_transactions returns early when nothing to sync" do
    result = @client.sync_unsynced_transactions
    assert_equal 0, result[:synced_count]
    assert_empty result[:transaction_ids]
  end

  test "sync_unsynced_transactions imports transactions and updates database records" do
    tx1 = Transaction.create!(payee: "Coffee Shop", amount: -3.50, occurred_at: Time.utc(2026, 10, 11), synced_to_actual: false)
    tx2 = Transaction.create!(payee: "Salary", amount: 1500.00, occurred_at: Time.utc(2026, 10, 11), synced_to_actual: nil)

    expected_path = "/budgets/test-budget-sync-id/accounts/test-account-id/transactions/import"
    mock_response = Net::HTTPSuccess.new(1.0, "201", "Created")
    mock_response.instance_variable_set(:@read, true)
    allow_body = { "data" => { "added" => [ "uuid-1", "uuid-2" ], "updated" => [] } }.to_json
    mock_response.stubs(:body).returns(allow_body) if mock_response.respond_to?(:stubs)

    requested_body = nil
    requested_headers = {}

    Net::HTTP.any_instance.stubs(:request).with do |req|
      requested_body = JSON.parse(req.body)
      requested_headers["x-api-key"] = req["x-api-key"]
      requested_headers["Content-Type"] = req["Content-Type"]
      true
    end.returns(mock_response) rescue nil

    # Test using a block mock on Net::HTTP#request
    Net::HTTP.class_eval do
      alias_method :orig_request, :request
      define_method(:request) do |req|
        if req.path.include?("transactions/import")
          Thread.current[:last_actual_request_body] = JSON.parse(req.body)
          Thread.current[:last_actual_request_headers] = {
            "x-api-key" => req["x-api-key"],
            "Content-Type" => req["Content-Type"]
          }
          mock_res = Net::HTTPCreated.new("1.1", 201, "Created")
          mock_res.instance_variable_set(:@read, true)
          def mock_res.body
            { "data" => { "added" => [ "uuid-1", "uuid-2" ], "updated" => [] } }.to_json
          end
          mock_res
        else
          orig_request(req)
        end
      end
    end

    begin
      result = @client.sync_unsynced_transactions

      assert_equal 2, result[:synced_count]
      assert_equal [ tx1.id, tx2.id ], result[:transaction_ids]
      assert_equal [ "uuid-1", "uuid-2" ], result[:added]

      # Verify database updated
      assert_equal true, tx1.reload.synced_to_actual
      assert_equal true, tx2.reload.synced_to_actual

      # Verify payload sent
      sent_body = Thread.current[:last_actual_request_body]
      assert_equal 2, sent_body["transactions"].size
      assert_equal(-350, sent_body["transactions"][0]["amount"])
      assert_equal 150000, sent_body["transactions"][1]["amount"]
      assert_equal "Coffee Shop", sent_body["transactions"][0]["payee_name"]
      assert_equal "Salary", sent_body["transactions"][1]["payee_name"]

      # Verify headers
      sent_headers = Thread.current[:last_actual_request_headers]
      assert_equal "test-api-key", sent_headers["x-api-key"]
      assert_equal "application/json", sent_headers["Content-Type"]
    ensure
      Net::HTTP.class_eval do
        alias_method :request, :orig_request
        remove_method :orig_request
      end
      Thread.current[:last_actual_request_body] = nil
      Thread.current[:last_actual_request_headers] = nil
    end
  end

  test "sync_unsynced_transactions raises ApiError and leaves records unsynced on API error" do
    tx = Transaction.create!(payee: "Failed Shop", amount: -10.00, synced_to_actual: false)

    Net::HTTP.class_eval do
      alias_method :orig_request, :request
      define_method(:request) do |req|
        if req.path.include?("transactions/import")
          mock_res = Net::HTTPInternalServerError.new("1.1", 500, "Internal Server Error")
          mock_res.instance_variable_set(:@read, true)
          def mock_res.body
            { "error" => "Database connection failure in Actual Server" }.to_json
          end
          mock_res
        else
          orig_request(req)
        end
      end
    end

    begin
      assert_raises(ActualClient::ApiError) do
        @client.sync_unsynced_transactions
      end

      # Should still be false in DB
      assert_equal false, tx.reload.synced_to_actual
    ensure
      Net::HTTP.class_eval do
        alias_method :request, :orig_request
        remove_method :orig_request
      end
    end
  end

  test "resolves account id from account_name using id_by_name" do
    client = ActualClient.new(
      base_url: "https://api.actual.int.alexmmd.com",
      api_key: "test-api-key",
      budget_sync_id: "test-budget-sync-id",
      account_name: "Trading 212"
    )

    Net::HTTP.class_eval do
      alias_method :orig_request, :request
      define_method(:request) do |req|
        if req.path.include?("id-by-name")
          mock_res = Net::HTTPOK.new("1.1", 200, "OK")
          mock_res.instance_variable_set(:@read, true)
          def mock_res.body
            { "data" => "resolved-account-uuid" }.to_json
          end
          mock_res
        else
          orig_request(req)
        end
      end
    end

    begin
      assert_equal "resolved-account-uuid", client.resolve_account_id
      assert_equal "resolved-account-uuid", client.account_id
    ensure
      Net::HTTP.class_eval do
        alias_method :request, :orig_request
        remove_method :orig_request
      end
    end
  end

  test "includes budget-encryption-password header when present" do
    client = ActualClient.new(
      base_url: "https://api.actual.int.alexmmd.com",
      api_key: "test-api-key",
      budget_sync_id: "test-budget-sync-id",
      account_id: "test-account-id",
      encryption_password: "my-secret-budget-pass"
    )

    captured_headers = {}
    Net::HTTP.class_eval do
      alias_method :orig_request, :request
      define_method(:request) do |req|
        if req.path.include?("/budgets/test-budget-sync-id/accounts")
          captured_headers["budget-encryption-password"] = req["budget-encryption-password"]
          mock_res = Net::HTTPOK.new("1.1", 200, "OK")
          mock_res.instance_variable_set(:@read, true)
          def mock_res.body
            { "data" => [] }.to_json
          end
          mock_res
        else
          orig_request(req)
        end
      end
    end

    begin
      client.get_accounts
      assert_equal "my-secret-budget-pass", captured_headers["budget-encryption-password"]
    ensure
      Net::HTTP.class_eval do
        alias_method :request, :orig_request
        remove_method :orig_request
      end
    end
  end

  test "ActualHttpClient subclasses ActualClient" do
    assert ActualHttpClient < ActualClient
  end
end
