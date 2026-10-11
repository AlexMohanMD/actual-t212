# Calls the Trading212 API service
# Detects balance drift between the calculated spending pot balance and the actual balance from Trading212
# Inserts a record of the balance drift into the output

class SyncWithBalance
  def initialize
    if SyncState.first.nil?
      # Initialize the sync state if it doesn't exist
      SyncState.create!
    end
  end

  def call
    end_time = Time.now.strftime("%Y-%m-%dT%H:%M:%SZ")
    result = SyncTrading212.new.call(initialize_start_time, end_time)
    result[:csv_data][:transactions].select { |t| t["Action"] == "Withdrawal" }.each do |transaction|
      Transaction.create!(
        amount: transaction["Total"],
        payee: "Withdrawal",
        notes: transaction["Notes"],
        occurred_at: transaction["Time (UTC)"]
      )
    end
    result[:csv_data][:transactions].select { |t| t["Action"] == "Deposit" }.each do |transaction|
      Transaction.create!(
        amount: transaction["Total"],
        payee: "Deposit",
        notes: transaction["Notes"],
        occurred_at: transaction["Time (UTC)"]
      )
    end
    result[:csv_data][:transactions].select { |t| t["Action"] == "Card debit" || t["Action"] == "Card credit" }.each do |transaction|
      Transaction.create!(
        amount: transaction["Total"],
        payee: transaction["Merchant name"],
        notes: [transaction["Merchant category"], transaction["Notes"]].compact.join(" "),
        occurred_at: transaction["Time (UTC)"]
      )
    end
    Transaction.create!(
      amount: result[:csv_data][:totals][:interest_total],
      payee: "Interest on cash",
      notes: "Between " << Time.parse(initialize_start_time).utc.strftime("%d %B %Y") << " and " << Time.now.utc.strftime("%d %B %Y"),
      occurred_at: Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
    )
    Transaction.create!(
      amount: result[:csv_data][:totals][:cashback_total],
      payee: "Cashback",
      notes: "Between " << Time.parse(initialize_start_time).utc.strftime("%d %B %Y") << " and " << Time.now.utc.strftime("%d %B %Y"),
      occurred_at: Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
    )
    detect_balance_drift(result)
    SyncState.first.update!(last_synced_at: Time.now.utc, last_balance: result[:spending_pot_balance])
  end

  private

  def initialize_start_time
    if SyncState.first.last_synced_at.nil?
      # Set the sync start time variable to the current time minus 3 months and store in variable
      # normalise to a string "YYYY-MM-DDTHH:MM:SSZ"
      3.months.ago.strftime("%Y-%m-%dT%H:%M:%SZ")
    else
      SyncState.first.last_synced_at.strftime("%Y-%m-%dT%H:%M:%SZ")
    end
  end
  def detect_balance_drift(result)
    unless SyncState.first.last_balance.nil?
      # Take the transactions from the result and calculate the new balance
      calculated_balance = SyncState.first.last_balance + result[:csv_data][:transactions].sum { |t| t["Total"].to_f }
      # If there's balance drift, create a transaction to balance the total
      if calculated_balance != result[:spending_pot_balance]
        Transaction.create!(
          amount: calculated_balance - result[:spending_pot_balance],
          payee: "Balance Adjustment",
          notes: "Adjusting for balance drift",
          occurred_at: Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
        )
      end
    end
  end
end
