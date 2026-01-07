class Provider::Trading212
  include HTTParty

  BASE_URL = "https://live.trading212.com/api/v0".freeze

  headers "User-Agent" => "Sure Finance Trading212 Client"
  default_options.merge!(verify: true, ssl_verify_mode: OpenSSL::SSL::VERIFY_PEER, timeout: 120)

  attr_reader :api_key, :api_secret

  def initialize(api_key, api_secret)
    @api_key = api_key
    @api_secret = api_secret
  end

  # Get account summary (balance info)
  # Returns: { id, currency, totalValue, cash: {...}, investments: {...} }
  def get_account_summary
    response = self.class.get(
      "#{BASE_URL}/equity/account/summary",
      headers: auth_headers
    )

    handle_response(response)
  rescue SocketError, Net::OpenTimeout, Net::ReadTimeout => e
    Rails.logger.error "Trading212 API: GET /equity/account/summary failed: #{e.class}: #{e.message}"
    raise Trading212Error.new("Exception during GET request: #{e.message}", :request_failed)
  rescue => e
    Rails.logger.error "Trading212 API: Unexpected error during GET /equity/account/summary: #{e.class}: #{e.message}"
    raise Trading212Error.new("Exception during GET request: #{e.message}", :request_failed)
  end

  # Calculate spending balance from account summary
  # Formula: totalValue - investments.currentValue - cash.availableToTrade
  # @param summary [Hash] Optional pre-fetched account summary (to avoid extra API call)
  # @return [Hash] { balance: BigDecimal, currency: String }
  def get_spending_balance(summary = nil)
    summary ||= get_account_summary

    total_value = BigDecimal(summary[:totalValue].to_s)
    investments_value = BigDecimal(summary.dig(:investments, :currentValue).to_s)
    available_to_trade = BigDecimal(summary.dig(:cash, :availableToTrade).to_s)

    spending_balance = total_value - investments_value - available_to_trade

    {
      balance: spending_balance,
      currency: summary[:currency],
      account_id: summary[:id],
      raw_summary: summary
    }
  end

  # Create an export request for transactions
  # @param time_from [Time, DateTime, String] Start time
  # @param time_to [Time, DateTime, String] End time
  # @return [Hash] { reportId: Integer }
  def create_export(time_from:, time_to:)
    body = {
      dataIncluded: {
        includeTransactions: true,
        includeOrders: true,
        includeDividends: true
      },
      timeFrom: format_time(time_from),
      timeTo: format_time(time_to)
    }

    response = self.class.post(
      "#{BASE_URL}/equity/history/exports",
      headers: auth_headers,
      body: body.to_json
    )

    handle_response(response)
  rescue SocketError, Net::OpenTimeout, Net::ReadTimeout => e
    Rails.logger.error "Trading212 API: POST /equity/history/exports failed: #{e.class}: #{e.message}"
    raise Trading212Error.new("Exception during POST request: #{e.message}", :request_failed)
  rescue => e
    Rails.logger.error "Trading212 API: Unexpected error during POST /equity/history/exports: #{e.class}: #{e.message}"
    raise Trading212Error.new("Exception during POST request: #{e.message}", :request_failed)
  end

  # Get all exports
  # @return [Array<Hash>] List of export reports
  def get_exports
    response = self.class.get(
      "#{BASE_URL}/equity/history/exports",
      headers: auth_headers
    )

    handle_response(response)
  rescue SocketError, Net::OpenTimeout, Net::ReadTimeout => e
    Rails.logger.error "Trading212 API: GET /equity/history/exports failed: #{e.class}: #{e.message}"
    raise Trading212Error.new("Exception during GET request: #{e.message}", :request_failed)
  rescue => e
    Rails.logger.error "Trading212 API: Unexpected error during GET /equity/history/exports: #{e.class}: #{e.message}"
    raise Trading212Error.new("Exception during GET request: #{e.message}", :request_failed)
  end

  # Find an export by report ID
  # @param report_id [Integer] The report ID to find
  # @return [Hash, nil] The export report or nil if not found
  def find_export(report_id)
    exports = get_exports
    exports.find { |export| export[:reportId] == report_id }
  end

  # Wait for an export to finish and return the download link
  # @param report_id [Integer] The report ID to wait for
  # @param max_attempts [Integer] Maximum number of polling attempts
  # @param initial_delay [Integer] Seconds to wait before first check (usually ready quickly)
  # @param poll_interval [Integer] Seconds between subsequent checks (rate limit applies after first GET)
  # @return [String] The presigned download URL
  def wait_for_export(report_id, max_attempts: 10, initial_delay: 10, poll_interval: 60)
    # Wait before first check (exports usually complete quickly)
    Rails.logger.info "Trading212 API: Waiting #{initial_delay}s before first check for export #{report_id}"
    sleep(initial_delay)

    attempts = 0

    loop do
      attempts += 1
      export = find_export(report_id)

      if export.nil?
        raise Trading212Error.new("Export #{report_id} not found", :not_found)
      end

      case export[:status]
      when "Finished"
        return export[:downloadLink]
      when "Failed"
        raise Trading212Error.new("Export #{report_id} failed", :export_failed)
      else
        if attempts >= max_attempts
          raise Trading212Error.new("Export #{report_id} timed out after #{max_attempts} attempts", :timeout)
        end

        # Rate limit kicks in after first GET, must wait 60s between subsequent checks
        Rails.logger.info "Trading212 API: Export #{report_id} status: #{export[:status]}, waiting #{poll_interval}s (attempt #{attempts}/#{max_attempts})"
        sleep(poll_interval)
      end
    end
  end

  # Download CSV from presigned URL
  # @param download_url [String] The presigned S3 URL
  # @return [String] The CSV content
  def download_csv(download_url)
    response = self.class.get(download_url)

    if response.code == 200
      response.body
    else
      raise Trading212Error.new("Failed to download CSV: #{response.code}", :download_failed)
    end
  rescue SocketError, Net::OpenTimeout, Net::ReadTimeout => e
    Rails.logger.error "Trading212 API: Failed to download CSV: #{e.class}: #{e.message}"
    raise Trading212Error.new("Exception during CSV download: #{e.message}", :request_failed)
  end

  # Parse CSV content into transaction records
  # @param csv_content [String] The CSV content
  # @return [Array<Hash>] Parsed transactions
  def parse_transactions(csv_content)
    require "csv"

    transactions = []
    CSV.parse(csv_content, headers: true) do |row|
      transactions << {
        action: row["Action"],
        time: row["Time"],
        id: row["ID"],
        amount: row["Total"]&.to_d,
        currency: row["Currency (Total)"]&.delete('"'),
        merchant_name: row["Merchant name"],
        merchant_category: row["Merchant category"],
        # Investment order fields
        isin: row["ISIN"],
        ticker: row["Ticker"],
        stock_name: row["Name"]&.delete('"'),
        shares: row["No. of shares"]&.to_d,
        price_per_share: row["Price / share"]&.to_d,
        share_currency: row["Currency (Price / share)"]&.delete('"'),
        notes: row["Notes"],
        # Dividend fields
        withholding_tax: row["Withholding tax"]&.to_d,
        withholding_tax_currency: row["Currency (Withholding tax)"]&.delete('"')
      }
    end

    transactions
  end

  # High-level method to fetch transactions for a date range
  # Creates an export, waits for it, downloads and parses the CSV
  # @param time_from [Time, DateTime, String] Start time
  # @param time_to [Time, DateTime, String] End time
  # @return [Array<Hash>] Parsed transactions
  def fetch_transactions(time_from:, time_to:)
    # Create the export request
    result = create_export(time_from: time_from, time_to: time_to)
    report_id = result[:reportId]

    Rails.logger.info "Trading212 API: Created export #{report_id} for #{time_from} to #{time_to}"

    # Wait for export to complete
    download_url = wait_for_export(report_id)

    # Download and parse CSV
    csv_content = download_csv(download_url)
    parse_transactions(csv_content)
  end

  private

    def auth_headers
      credentials = Base64.strict_encode64("#{api_key}:#{api_secret}")
      {
        "Authorization" => "Basic #{credentials}",
        "Content-Type" => "application/json",
        "Accept" => "application/json"
      }
    end

    def format_time(time)
      case time
      when String
        time
      when Time, DateTime
        time.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
      when Date
        time.to_datetime.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
      else
        time.to_s
      end
    end

    def handle_response(response)
      case response.code
      when 200, 201
        JSON.parse(response.body, symbolize_names: true)
      when 400
        Rails.logger.error "Trading212 API: Bad request - #{response.body}"
        raise Trading212Error.new("Bad request to Trading212 API: #{response.body}", :bad_request)
      when 401
        raise Trading212Error.new("Invalid API credentials", :unauthorized)
      when 403
        raise Trading212Error.new("Access forbidden - check your API credentials", :access_forbidden)
      when 404
        raise Trading212Error.new("Resource not found", :not_found)
      when 429
        raise Trading212Error.new("Rate limit exceeded. Please try again later.", :rate_limited)
      else
        Rails.logger.error "Trading212 API: Unexpected response - Code: #{response.code}, Body: #{response.body}"
        raise Trading212Error.new("Failed to fetch data: #{response.code} #{response.message} - #{response.body}", :fetch_failed)
      end
    end

    class Trading212Error < StandardError
      attr_reader :error_type

      def initialize(message, error_type = :unknown)
        super(message)
        @error_type = error_type
      end
    end
end
