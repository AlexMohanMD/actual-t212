require "test_helper"

class SyncWithBalanceTest < ActiveSupport::TestCase
  class DummyActualClient
    attr_accessor :transactions_response, :balance_response

    def initialize(transactions: [], balance_in_minor_units: 45398)
      @transactions_response = { "data" => transactions }
      @balance_response = { "data" => balance_in_minor_units }
    end

    def get_transactions(account_id: nil, since_date: nil, until_date: nil, page: nil, limit: nil)
      @transactions_response
    end

    def get_account_balance(account_id: nil, cutoff_date: nil)
      @balance_response
    end

    def account_balance_amount(account_id: nil, cutoff_date: nil)
      return nil unless @balance_response.is_a?(Hash) && @balance_response.key?("data")
      BigDecimal(@balance_response["data"].to_s) / 100
    end
  end

  class DummyTrading212Client
    attr_accessor :result

    def initialize(result = nil)
      @result = result || {
        csv_data: {
          totals: { interest_total: 1.25, cashback_total: 0.50 },
          transactions: [
            {
              "Action" => "Card debit",
              "ID" => "t212-tx-uuid-1",
              "Time (UTC)" => "2026-10-10 12:00:00+00:00",
              "Merchant name" => "Tesco",
              "Merchant category" => "Groceries",
              "Notes" => nil,
              "Total" => "-15.00"
            },
            {
              "Action" => "Deposit",
              "ID" => "t212-tx-uuid-2",
              "Time (UTC)" => "2026-10-10 10:00:00+00:00",
              "Notes" => "Top up",
              "Total" => "100.00"
            },
            {
              "Action" => "Withdrawal",
              "ID" => "t212-tx-uuid-3",
              "Time (UTC)" => "2026-10-10 11:00:00+00:00",
              "Notes" => "Transfer out",
              "Total" => "-20.00"
            }
          ]
        },
        spending_pot_balance: BigDecimal("500.00")
      }
    end

    def call(start_time, end_time)
      @result
    end
  end

  setup do
    Transaction.delete_all
    SyncState.delete_all
  end

  test "initialize populates SyncState from Actual when SyncState is empty and Actual has transactions" do
    actual_txs = [
      {
        "id" => "act-1",
        "imported_id" => "019e877b-ce80-7ed2-8736-12d0a0445f65",
        "date" => "2026-10-09",
        "amount" => -1000
      },
      {
        "id" => "act-2",
        "imported_id" => "INT-2026-10-11T14:31:48Z",
        "date" => "2026-10-11",
        "amount" => 0
      },
      {
        "id" => "act-3",
        "imported_id" => "CSH-2026-10-11T14:31:48Z",
        "date" => "2026-10-11",
        "amount" => 0
      }
    ]

    mock_client = DummyActualClient.new(transactions: actual_txs, balance_in_minor_units: 45398)

    assert_equal 0, SyncState.count

    SyncWithBalance.new(actual_client: mock_client)

    assert_equal 1, SyncState.count
    state = SyncState.first
    assert_equal Time.utc(2026, 10, 11, 14, 31, 48), state.last_synced_at
    assert_equal BigDecimal("453.98"), state.last_balance
  end

  test "initialize handles empty Actual account by creating SyncState with nil values" do
    mock_client = DummyActualClient.new(transactions: [], balance_in_minor_units: 0)

    SyncWithBalance.new(actual_client: mock_client)

    assert_equal 1, SyncState.count
    state = SyncState.first
    assert_nil state.last_synced_at
    assert_nil state.last_balance
  end

  test "initialize does not overwrite already populated SyncState" do
    SyncState.create!(
      last_synced_at: Time.utc(2026, 10, 1, 9, 0, 0),
      last_balance: BigDecimal("150.00")
    )

    mock_client = DummyActualClient.new(
      transactions: [ { "imported_id" => "INT-2026-10-11T14:31:48Z" } ],
      balance_in_minor_units: 99900
    )

    SyncWithBalance.new(actual_client: mock_client)

    state = SyncState.first
    assert_equal Time.utc(2026, 10, 1, 9, 0, 0), state.last_synced_at
    assert_equal BigDecimal("150.00"), state.last_balance
  end

  test "call pulls CSV ID into imported_id and invents INT, CSH, ADJ with timestamps" do
    SyncState.create!(
      last_synced_at: Time.utc(2026, 10, 10, 0, 0, 0),
      last_balance: BigDecimal("435.00") # Calculated balance will be 435 + (-15 + 100 - 20) = 500, equal to pot balance
    )

    trading212 = DummyTrading212Client.new
    sync = SyncWithBalance.new(trading212_client: trading212)

    assert_difference "Transaction.count", 5 do
      sync.call
    end

    # Verify CSV transactions have their ID
    debit = Transaction.find_by(payee: "Tesco")
    assert_equal "t212-tx-uuid-1", debit.imported_id
    assert_equal BigDecimal("-15.00"), debit.amount

    deposit = Transaction.find_by(payee: "Deposit")
    assert_equal "t212-tx-uuid-2", deposit.imported_id
    assert_equal BigDecimal("100.00"), deposit.amount

    withdrawal = Transaction.find_by(payee: "Withdrawal")
    assert_equal "t212-tx-uuid-3", withdrawal.imported_id
    assert_equal BigDecimal("-20.00"), withdrawal.amount

    # Verify invented transactions have deterministic INT and CSH imported_ids
    interest = Transaction.find_by(payee: "Interest on cash")
    assert interest.present?
    assert_match(/\AINT-\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/, interest.imported_id)
    assert_equal BigDecimal("1.25"), interest.amount

    cashback = Transaction.find_by(payee: "Cashback")
    assert cashback.present?
    assert_match(/\ACSH-\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/, cashback.imported_id)
    assert_equal BigDecimal("0.50"), cashback.amount

    # Verify SyncState updated
    assert_equal BigDecimal("500.00"), SyncState.first.last_balance
  end

  test "call creates ADJ transaction with timestamp when balance drift occurs" do
    SyncState.create!(
      last_synced_at: Time.utc(2026, 10, 10, 0, 0, 0),
      last_balance: BigDecimal("400.00") # Calculated will be 400 + 65 = 465, but pot is 500
    )

    trading212 = DummyTrading212Client.new
    sync = SyncWithBalance.new(trading212_client: trading212)

    assert_difference "Transaction.count", 6 do
      sync.call
    end

    adj = Transaction.find_by(payee: "Balance Adjustment")
    assert adj.present?
    assert_match(/\AADJ-\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/, adj.imported_id)
    assert_equal BigDecimal("-35.00"), adj.amount # 465 - 500 = -35.0
  end

  test "call is idempotent for transactions already having imported_id" do
    SyncState.create!(
      last_synced_at: Time.utc(2026, 10, 10, 0, 0, 0),
      last_balance: BigDecimal("435.00")
    )

    # Pre-create the debit transaction
    Transaction.create!(
      imported_id: "t212-tx-uuid-1",
      payee: "Tesco",
      amount: -15.00
    )

    trading212 = DummyTrading212Client.new
    sync = SyncWithBalance.new(trading212_client: trading212)

    # Should only create 4 new transactions instead of 5
    assert_difference "Transaction.count", 4 do
      sync.call
    end
  end
end
