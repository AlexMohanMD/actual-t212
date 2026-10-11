## This class provides a client for interacting with the Trading212 API.
# It uses a personal API token to generate a CSV file with the latest spending pot transactions
# We then parse the CSV file and strip out interest on cash and spending cashback, and bundle these into a total per sync
# Finally, we normalise desposits and withdrawals as a standard transaction label.
# The remaining transactions will be standard spending transactions on the T212 spending pot, they have a merchant name associated with them.
# We record these on the DB, ready for the second step - the sync to Actual Budget (not handled by this service).


require "csv"
require "net/http"
require "uri"
require "json"

class SyncTrading212
  def call(start_time, end_time)
    report_id = post_csv_export(start_time, end_time)
    Rails.logger.info("Posted CSV export request, report ID: #{report_id}")
    puts("Waiting for CSV export to be ready...")
    sleep(60)
    result = normalise_csv(get_csv_download(report_id))
    Rails.logger.info("Normalised CSV result: #{result}")
    spending_pot_balance = get_spending_pot_balance
    { csv_data: result, spending_pot_balance: spending_pot_balance }
  end

  def get_spending_pot_balance
    uri = URI("https://live.trading212.com/api/v0/equity/account/summary")
    response = t212request(uri, nil, :get)
    summary = JSON.parse(response.body)
    spending_pot_balance = BigDecimal(summary["totalValue"].to_s) - BigDecimal(summary["cash"]["availableToTrade"].to_s) - BigDecimal(summary["cash"]["reservedForOrders"].to_s) - BigDecimal(summary["investments"]["currentValue"].to_s)
    spending_pot_balance
  end

  def normalise_csv(csv_content)
    transactions = CSV.parse(csv_content, headers: true)

    # Strip out interest on cash and spending cashback, and bundle these into a total per sync

    interest_total = transactions.select { |t| t["Action"] == "Interest on cash" }.sum { |t| t["Total"].to_f }
    cashback_total = transactions.select { |t| t["Action"] == "Spending cashback" }.sum { |t| t["Total"].to_f }

    totals = { interest_total: interest_total, cashback_total: cashback_total }
    transactions = transactions.reject { |t| t["Action"] == "Interest on cash" || t["Action"] == "Spending cashback" }
    { totals: totals, transactions: transactions }
  end

  def post_csv_export(start_time, end_time)
    body = {
      dataIncluded: {
        includeDividends: false,
        includeInterest: true,
        includeOrders: false,
        includeTransactions: true
      },
      timeFrom: start_time,
      timeTo: end_time
    }
    response = t212request(URI("https://live.trading212.com/api/v0/equity/history/exports"), body, :post)

    JSON.parse(response.body)["reportId"]
  end

  def get_csv_download(report_id)
    uri = URI("https://live.trading212.com/api/v0/equity/history/exports")
    response = t212request(uri, nil, :get)

    uri = URI(JSON.parse(response.body).find { |r| r["reportId"] == report_id }["downloadLink"])
    amzrequest(uri)
  end

  private

  def t212request(uri, body, method = :get)
    username = ENV.fetch("TRADING212_API_CLIENT_ID")
    password = ENV.fetch("TRADING212_API_CLIENT_SECRET")

    # Setup HTTP request, with username/password as basic auth credentials
    request = case method
    when :post
                Net::HTTP::Post.new(uri)
    when :get
                Net::HTTP::Get.new(uri)
    else
                raise ArgumentError, "Unsupported HTTP method: #{method}"
    end
    request.basic_auth(username, password)
    request.add_field("Content-Type", "application/json")
    request.body = body.to_json if body

    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
      http.request(request)
    end

    response
  end
  def amzrequest(uri)
    request = Net::HTTP::Get.new(uri)
    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
      http.request(request)
    end
    response.body.force_encoding(Encoding::UTF_8)
  end
end
