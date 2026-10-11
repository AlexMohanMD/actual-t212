# Client for Actual HTTP API (https://github.com/jhonderson/actual-http-api)
# Syncs transactions stored in the database to an Actual Budget account.

require "net/http"
require "uri"
require "json"
require "bigdecimal"

class ActualClient
  class Error < StandardError; end
  class ConfigurationError < Error; end
  class ApiError < Error
    attr_reader :status_code, :response

    def initialize(message, status_code: nil, response: nil)
      super(message)
      @status_code = status_code
      @response = response
    end
  end

  DEFAULT_BASE_URL = "https://api.actual.int.alexmmd.com".freeze

  attr_reader :base_url, :api_key, :budget_sync_id, :account_id, :account_name, :encryption_password

  def self.call(...)
    new.call(...)
  end

  def self.sync_unsynced_transactions(...)
    new.sync_unsynced_transactions(...)
  end

  def initialize(
    base_url: nil,
    api_key: nil,
    budget_sync_id: nil,
    account_id: nil,
    account_name: nil,
    encryption_password: nil
  )
    load_dotenv_if_needed! if ENV["ACTUAL_API_KEY"].blank?

    raw_base_url = base_url || ENV["ACTUAL_API_URL"] || ENV["ACTUAL_HTTP_API_URL"] || DEFAULT_BASE_URL
    @base_url = raw_base_url.to_s.chomp("/")
    @api_key = api_key || ENV["ACTUAL_API_KEY"] || ENV["ACTUAL_HTTP_API_KEY"]
    @budget_sync_id = budget_sync_id || ENV["ACTUAL_BUDGET_SYNC_ID"] || ENV["ACTUAL_SYNC_ID"]
    @account_id = account_id || ENV["ACTUAL_ACCOUNT_ID"]
    @account_name = account_name || ENV["ACTUAL_ACCOUNT_NAME"]
    @encryption_password = encryption_password ||
                           ENV["ACTUAL_BUDGET_ENCRYPTION_PASSWORD"] ||
                           ENV["ACTUAL_BUDGET_PASSWORD"] ||
                           ENV["ACTUAL_ENCRYPTION_PASSWORD"]
  end

  # Main runner method: fetches unsynced transactions from the DB,
  # imports them into Actual HTTP API, and marks them as synced in the DB.
  def call(batch_size: nil)
    sync_unsynced_transactions(batch_size: batch_size)
  end

  # Synchronizes unsynced transactions (or a provided scope) to Actual Budget.
  def sync_unsynced_transactions(scope = Transaction.unsynced, batch_size: nil)
    unsynced = scope.order(:occurred_at, :id).to_a
    if unsynced.empty?
      Rails.logger.info("ActualClient: No unsynced transactions to sync.")
      return { synced_count: 0, transaction_ids: [], added: [], updated: [] }
    end

    validate_credentials!
    target_account_id = resolve_account_id
    Rails.logger.info("ActualClient: Syncing #{unsynced.size} transactions to Actual Budget account #{target_account_id}...")

    total_added = []
    total_updated = []
    synced_records = []

    batches = batch_size ? unsynced.each_slice(batch_size) : [ unsynced ]

    batches.each do |batch|
      formatted_transactions = batch.map { |tx| format_transaction(tx, account_id: target_account_id) }
      response = import_transactions(formatted_transactions, account_id: target_account_id)

      data = response.is_a?(Hash) && response["data"].is_a?(Hash) ? response["data"] : {}
      total_added.concat(data["added"]) if data["added"].is_a?(Array)
      total_updated.concat(data["updated"]) if data["updated"].is_a?(Array)

      # Mark successfully imported transactions as synced in DB
      batch_ids = batch.map(&:id)
      Transaction.where(id: batch_ids).update_all(synced_to_actual: true, updated_at: Time.current)
      synced_records.concat(batch_ids)
    end

    Rails.logger.info("ActualClient: Successfully synced #{synced_records.size} transactions to Actual Budget.")

    {
      synced_count: synced_records.size,
      transaction_ids: synced_records,
      added: total_added,
      updated: total_updated
    }
  end

  # Imports transactions into the account using the import endpoint.
  # POST /budgets/{budgetSyncId}/accounts/{accountId}/transactions/import
  def import_transactions(
    transactions,
    account_id: nil,
    default_cleared: true,
    dry_run: false,
    reimport_deleted: false,
    payee_name_normalization: "title-case"
  )
    validate_credentials!
    target_account = account_id || resolve_account_id

    body = {
      transactions: transactions,
      defaultCleared: default_cleared,
      dryRun: dry_run,
      reimportDeleted: reimport_deleted,
      payeeNameNormalization: payee_name_normalization
    }

    path = "/budgets/#{budget_sync_id}/accounts/#{target_account}/transactions/import"
    request(:post, path, body: body)
  end

  # Creates multiple transactions in a batch.
  # POST /budgets/{budgetSyncId}/accounts/{accountId}/transactions/batch
  def batch_transactions(transactions, account_id: nil, learn_categories: false, run_transfers: false)
    validate_credentials!
    target_account = account_id || resolve_account_id

    body = {
      transactions: transactions,
      learnCategories: learn_categories,
      runTransfers: run_transfers
    }

    path = "/budgets/#{budget_sync_id}/accounts/#{target_account}/transactions/batch"
    request(:post, path, body: body)
  end

  # Creates a single transaction.
  # POST /budgets/{budgetSyncId}/accounts/{accountId}/transactions
  def create_transaction(transaction, account_id: nil, learn_categories: false, run_transfers: false)
    validate_credentials!
    target_account = account_id || resolve_account_id

    body = {
      transaction: transaction,
      learnCategories: learn_categories,
      runTransfers: run_transfers
    }

    path = "/budgets/#{budget_sync_id}/accounts/#{target_account}/transactions"
    request(:post, path, body: body)
  end

  # Returns transactions for an account.
  # GET /budgets/{budgetSyncId}/accounts/{accountId}/transactions
  def get_transactions(account_id: nil, since_date: nil, until_date: nil, page: nil, limit: nil)
    validate_credentials!
    target_account = account_id || resolve_account_id

    query = {}
    query[:since_date] = since_date if since_date
    query[:until_date] = until_date if until_date
    query[:page] = page if page
    query[:limit] = limit if limit

    path = "/budgets/#{budget_sync_id}/accounts/#{target_account}/transactions"
    request(:get, path, query: query)
  end

  # Returns accounts in the budget.
  # GET /budgets/{budgetSyncId}/accounts
  def get_accounts
    validate_credentials!(require_account: false)
    path = "/budgets/#{budget_sync_id}/accounts"
    request(:get, path)
  end

  # Returns list of all budget files.
  # GET /budgets
  def get_budgets
    request(:get, "/budgets")
  end

  # Looks up the ID of an entity (e.g., 'accounts', 'payees', 'categories') by name.
  # GET /budgets/{budgetSyncId}/id-by-name
  def id_by_name(type, name)
    validate_credentials!(require_account: false)
    path = "/budgets/#{budget_sync_id}/id-by-name"
    request(:get, path, query: { type: type, name: name })
  end

  # Returns the version of the Actual HTTP API.
  # GET /actualhttpapiversion
  def server_version
    request(:get, "/actualhttpapiversion")
  end

  # Resolves the account ID, using @account_id or looking it up by @account_name.
  def resolve_account_id
    return @account_id if @account_id.present?

    if @account_name.present?
      lookup_res = id_by_name("accounts", @account_name) rescue nil
      if lookup_res.is_a?(Hash) && lookup_res["data"].present?
        @account_id = lookup_res["data"]
        return @account_id
      end

      # Fallback: find by name in get_accounts
      accounts_res = get_accounts rescue nil
      if accounts_res.is_a?(Hash) && accounts_res["data"].is_a?(Array)
        matched = accounts_res["data"].find { |acc| acc["name"] == @account_name }
        if matched && matched["id"]
          @account_id = matched["id"]
          return @account_id
        end
      end
    end

    raise ConfigurationError, "Missing Actual Account ID. Please set ACTUAL_ACCOUNT_ID (or ACTUAL_ACCOUNT_NAME) in ENV."
  end

  # Formats an Active Record Transaction record into the hash expected by Actual API.
  def format_transaction(transaction, account_id: nil)
    target_account = account_id || resolve_account_id
    tx_date = format_date(transaction.occurred_at || transaction.created_at)

    {
      account: target_account,
      date: tx_date,
      amount: amount_in_minor_units(transaction.amount),
      payee_name: transaction.payee.presence || "Unknown",
      notes: transaction.notes.presence,
      imported_id: "t212-#{transaction.id}",
      cleared: true
    }.compact
  end

  # Converts human currency amount (e.g. -12.50 or 9.99) to minor units (integer cents/pence, e.g. -1250 or 999).
  def amount_in_minor_units(amount)
    return 0 if amount.nil?
    (BigDecimal(amount.to_s) * 100).round.to_i
  end

  # Formats date to YYYY-MM-DD.
  def format_date(timestamp)
    time = timestamp || Time.current
    if time.respond_to?(:strftime)
      time.strftime("%Y-%m-%d")
    else
      Date.parse(time.to_s).strftime("%Y-%m-%d")
    end
  rescue StandardError
    Date.current.strftime("%Y-%m-%d")
  end

  def validate_credentials!(require_account: true)
    if @api_key.blank?
      raise ConfigurationError, "Missing Actual API key. Please set ACTUAL_API_KEY in ENV."
    end

    if @budget_sync_id.blank?
      raise ConfigurationError, "Missing Actual Budget Sync ID. Please set ACTUAL_BUDGET_SYNC_ID in ENV."
    end

    if require_account && @account_id.blank? && @account_name.blank?
      raise ConfigurationError, "Missing Actual Account ID. Please set ACTUAL_ACCOUNT_ID (or ACTUAL_ACCOUNT_NAME) in ENV."
    end
  end

  # Constructs the full URL, ensuring the '/v1' prefix is included without duplicating.
  def endpoint_url(path)
    base = @base_url.sub(/\/v1\/?$/, "")
    cleaned_path = path.to_s
    cleaned_path = "/#{cleaned_path}" unless cleaned_path.start_with?("/")
    cleaned_path = "/v1#{cleaned_path}" unless cleaned_path.start_with?("/v1/")
    "#{base}#{cleaned_path}"
  end

  private

  def request(method, path, body: nil, query: nil)
    full_url = endpoint_url(path)
    uri = URI(full_url)
    uri.query = URI.encode_www_form(query) if query.present?

    req = case method
    when :get
            Net::HTTP::Get.new(uri)
    when :post
            Net::HTTP::Post.new(uri)
    when :patch
            Net::HTTP::Patch.new(uri)
    when :delete
            Net::HTTP::Delete.new(uri)
    else
            raise ArgumentError, "Unsupported HTTP method: #{method}"
    end

    req["Content-Type"] = "application/json"
    req["Accept"] = "application/json"
    req["x-api-key"] = @api_key if @api_key.present?
    req["budget-encryption-password"] = @encryption_password if @encryption_password.present?

    req.body = body.to_json if body.present?

    http = Net::HTTP.new(uri.hostname, uri.port)
    http.use_ssl = (uri.scheme == "https")
    http.open_timeout = 15
    http.read_timeout = 30

    response = http.request(req)

    unless response.is_a?(Net::HTTPSuccess)
      error_msg = parse_error_message(response)
      raise ApiError.new(
        "Actual API #{method.to_s.upcase} #{uri.path} failed with HTTP #{response.code}: #{error_msg}",
        status_code: response.code.to_i,
        response: response.body
      )
    end

    if response.body.present?
      JSON.parse(response.body)
    else
      {}
    end
  end

  def parse_error_message(response)
    parsed = JSON.parse(response.body) rescue nil
    if parsed.is_a?(Hash)
      parsed["error"] || parsed["message"] || response.body
    else
      response.body
    end
  end

  def load_dotenv_if_needed!
    return if defined?(Rails) && Rails.respond_to?(:env) && Rails.env.test?

    if defined?(Dotenv)
      Dotenv.load
    else
      env_file = Rails.root.join(".env") if defined?(Rails) && Rails.respond_to?(:root)
      env_file ||= File.expand_path(".env", Dir.pwd)
      if File.exist?(env_file)
        File.foreach(env_file) do |line|
          line = line.strip
          next if line.empty? || line.start_with?("#")

          key, val = line.split("=", 2)
          if key && val
            clean_val = val.strip.sub(/\A['"](.*)['"]\z/m, '\1')
            ENV[key.strip] ||= clean_val
          end
        end
      end
    end
  end
end
