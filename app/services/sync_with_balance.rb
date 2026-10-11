# Calls the Trading212 API service
# Detects balance drift between the calculated spending pot balance and the actual balance from Trading212
# Inserts a record of the balance drift into the output

class SyncWithBalance
  attr_reader :actual_client, :trading212_client

  def initialize(actual_client: nil, trading212_client: nil)
    @actual_client = actual_client
    @trading212_client = trading212_client
    initialize_sync_state
  end

  def call
    sync_time = Time.now.utc
    end_time = sync_time.strftime("%Y-%m-%dT%H:%M:%SZ")
    result = (@trading212_client || SyncTrading212.new).call(initialize_start_time, end_time)

    result[:csv_data][:transactions].select { |t| t["Action"] == "Withdrawal" }.each do |transaction|
      next if transaction["ID"].present? && Transaction.exists?(imported_id: transaction["ID"])

      Transaction.create!(
        imported_id: transaction["ID"],
        amount: transaction["Total"],
        payee: "Withdrawal",
        notes: transaction["Notes"],
        occurred_at: transaction["Time (UTC)"]
      )
    end

    result[:csv_data][:transactions].select { |t| t["Action"] == "Deposit" }.each do |transaction|
      next if transaction["ID"].present? && Transaction.exists?(imported_id: transaction["ID"])

      Transaction.create!(
        imported_id: transaction["ID"],
        amount: transaction["Total"],
        payee: "Deposit",
        notes: transaction["Notes"],
        occurred_at: transaction["Time (UTC)"]
      )
    end

    result[:csv_data][:transactions].select { |t| t["Action"] == "Card debit" || t["Action"] == "Card credit" }.each do |transaction|
      next if transaction["ID"].present? && Transaction.exists?(imported_id: transaction["ID"])

      Transaction.create!(
        imported_id: transaction["ID"],
        amount: transaction["Total"],
        payee: transaction["Merchant name"],
        notes: [transaction["Merchant category"], transaction["Notes"]].compact.join(" "),
        occurred_at: transaction["Time (UTC)"]
      )
    end

    interest_id = "INT-#{end_time}"
    unless Transaction.exists?(imported_id: interest_id)
      start_date_str = Time.parse(initialize_start_time).utc.strftime("%d %B %Y")
      end_date_str = sync_time.strftime("%d %B %Y")
      Transaction.create!(
        imported_id: interest_id,
        amount: result[:csv_data][:totals][:interest_total],
        payee: "Interest on cash",
        notes: "Between #{start_date_str} and #{end_date_str}",
        occurred_at: end_time
      )
    end

    cashback_id = "CSH-#{end_time}"
    unless Transaction.exists?(imported_id: cashback_id)
      start_date_str = Time.parse(initialize_start_time).utc.strftime("%d %B %Y")
      end_date_str = sync_time.strftime("%d %B %Y")
      Transaction.create!(
        imported_id: cashback_id,
        amount: result[:csv_data][:totals][:cashback_total],
        payee: "Cashback",
        notes: "Between #{start_date_str} and #{end_date_str}",
        occurred_at: end_time
      )
    end

    detect_balance_drift(result, end_time)
    SyncState.first.update!(last_synced_at: sync_time, last_balance: result[:spending_pot_balance])
  end

  private

  def initialize_sync_state
    sync_state = SyncState.first
    return if sync_state.present? && (sync_state.last_synced_at.present? || sync_state.last_balance.present?)

    sync_state ||= SyncState.new

    begin
      client = @actual_client || ActualClient.new
      response = client.get_transactions
      actual_txs = (response.is_a?(Hash) && response["data"].is_a?(Array)) ? response["data"] : []

      if actual_txs.any?
        latest_timestamp = actual_txs.map { |tx| extract_transaction_timestamp(tx) }.compact.max
        balance = client.account_balance_amount

        if latest_timestamp.present?
          sync_state.last_synced_at = latest_timestamp
          sync_state.last_balance = balance if balance.present?
          sync_state.save!
          return
        end
      end
    rescue StandardError => e
      Rails.logger.warn("SyncWithBalance: Could not initialize from Actual account: #{e.message}")
    end

    sync_state.save! if sync_state.new_record?
  end

  def extract_transaction_timestamp(tx)
    imported_id = tx["imported_id"].to_s.strip

    # 1. Invented transactions: (INT|CSH|ADJ)-<timestamp> or <timestamp>-(INT|CSH|ADJ)
    if imported_id =~ /\A(?:(INT|CSH|ADJ)[-_](.+)|(.+)[-_](INT|CSH|ADJ))\z/
      ts_str = $2 || $3
      begin
        return Time.parse(ts_str).utc
      rescue ArgumentError, TypeError
        nil
      end
    end

    # 2. Match imported_id with existing local Transaction record
    if imported_id.present?
      db_tx = Transaction.find_by(imported_id: imported_id)
      return db_tx.occurred_at.utc if db_tx&.occurred_at.present?
    end

    # 3. Legacy imported_id format: t212-<id>
    if imported_id =~ /\At212-(\d+)\z/
      db_tx = Transaction.find_by(id: $1)
      return db_tx.occurred_at.utc if db_tx&.occurred_at.present?
    end

    # 4. UUIDv7 timestamp in imported_id
    if imported_id =~ /\A01[0-9a-f]{6}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i
      ms = imported_id.delete("-")[0..11].to_i(16)
      return Time.at(ms / 1000.0).utc
    end

    # 5. Fallback to transaction date in Actual (e.g. "2026-10-11")
    if tx["date"].present?
      begin
        return Time.parse(tx["date"]).utc
      rescue ArgumentError, TypeError
        nil
      end
    end

    nil
  end

  def initialize_start_time
    if SyncState.first.last_synced_at.nil?
      # Set the sync start time variable to the current time minus 3 months and store in variable
      # normalise to a string "YYYY-MM-DDTHH:MM:SSZ"
      3.months.ago.strftime("%Y-%m-%dT%H:%M:%SZ")
    else
      SyncState.first.last_synced_at.strftime("%Y-%m-%dT%H:%M:%SZ")
    end
  end

  def detect_balance_drift(result, sync_time_str = nil)
    sync_time_str ||= Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
    unless SyncState.first.last_balance.nil?
      # Take the transactions from the result and calculate the new balance
      calculated_balance = SyncState.first.last_balance + result[:csv_data][:transactions].sum { |t| t["Total"].to_f }
      # If there's balance drift, create a transaction to balance the total
      if calculated_balance != result[:spending_pot_balance]
        adj_id = "ADJ-#{sync_time_str}"
        unless Transaction.exists?(imported_id: adj_id)
          Transaction.create!(
            imported_id: adj_id,
            amount: calculated_balance - result[:spending_pot_balance],
            payee: "Balance Adjustment",
            notes: "Adjusting for balance drift",
            occurred_at: sync_time_str
          )
        end
      end
    end
  end
end
