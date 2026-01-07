require "digest/md5"

class Trading212Entry::Processor
  include CurrencyNormalizable

  # trading212_transaction is the parsed hash from Trading 212 CSV
  # Structure: { action, time, id, amount, currency, merchant_name, merchant_category,
  #              isin, ticker, stock_name, shares, price_per_share, share_currency, notes }
  def initialize(trading212_transaction, trading212_account:)
    @trading212_transaction = trading212_transaction
    @trading212_account = trading212_account
  end

  def process
    unless account.present?
      Rails.logger.warn "Trading212Entry::Processor - No linked account for trading212_account #{trading212_account.id}, skipping transaction #{external_id}"
      return nil
    end

    # Skip certain transaction types that shouldn't be imported
    if skip_transaction?
      Rails.logger.debug "Trading212Entry::Processor - Skipping transaction #{external_id} with action '#{data[:action]}'"
      return nil
    end

    begin
      if investment_order?
        # Investment orders are only stored in investment account's payload
        # We create: Transfer (cash<->invest) + Trade (in invest account)
        import_investment_order
      else
        # Regular cash transactions including dividends
        import_cash_transaction
      end
    rescue ArgumentError => e
      Rails.logger.error "Trading212Entry::Processor - Validation error for transaction #{external_id}: #{e.message}"
      raise
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved => e
      Rails.logger.error "Trading212Entry::Processor - Failed to save transaction #{external_id}: #{e.message}"
      raise StandardError.new("Failed to import transaction: #{e.message}")
    rescue => e
      Rails.logger.error "Trading212Entry::Processor - Unexpected error processing transaction #{external_id}: #{e.class} - #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      raise StandardError.new("Unexpected error importing transaction: #{e.message}")
    end
  end

  private
    attr_reader :trading212_transaction, :trading212_account

    SKIPPED_ACTIONS = [].freeze

    def skip_transaction?
      SKIPPED_ACTIONS.include?(data[:action])
    end

    def import_cash_transaction
      import_adapter.import_transaction(
        external_id: external_id,
        amount: amount,
        currency: currency,
        date: date,
        name: name,
        source: "trading212",
        merchant: merchant,
        notes: notes
      )
    end

    # Handles investment orders (Market buy/sell, Limit buy/sell)
    # Creates: Transfer between Cash and Investment accounts + Trade entry
    def import_investment_order
      # Always create the Trade entry in the investment account
      trade_result = import_trade
      return nil unless trade_result

      # Create Transfer between accounts if BOTH are linked
      create_investment_transfer

      trade_result
    end

    # Creates a Transfer linking Cash and Investment accounts for stock purchases/sales
    def create_investment_transfer
      cash_t212_account = trading212_account.trading212_item.trading212_accounts.cash.first
      invest_t212_account = trading212_account.trading212_item.trading212_accounts.investment.first

      cash_account = cash_t212_account&.current_account
      invest_account = invest_t212_account&.current_account

      # Only create transfer if BOTH accounts are linked
      unless cash_account && invest_account
        Rails.logger.info "Trading212Entry::Processor - Skipping transfer creation, not all accounts linked (cash: #{cash_account&.id}, invest: #{invest_account&.id})"
        return nil
      end

      transfer_amount = BigDecimal(data[:amount].to_s).abs
      is_buy = data[:action]&.include?("buy")

      # For buys: Cash → Investment (money moves to buy stocks)
      # For sells: Investment → Cash (money returns from selling)
      if is_buy
        source_account = cash_account
        destination_account = invest_account
      else
        source_account = invest_account
        destination_account = cash_account
      end

      ticker = data[:ticker].presence || "Stock"

      # Create outflow transaction in source account
      outflow_entry = source_account.entries.find_or_initialize_by(
        external_id: "#{external_id}_transfer_out",
        source: "trading212"
      )
      outflow_entry.entryable ||= Transaction.new(kind: "funds_movement")
      outflow_entry.assign_attributes(
        amount: transfer_amount,  # positive = outflow
        currency: currency,
        date: date,
        name: "Transfer to #{destination_account.name}"
      )
      outflow_entry.save!

      # Create inflow transaction in destination account
      inflow_entry = destination_account.entries.find_or_initialize_by(
        external_id: "#{external_id}_transfer_in",
        source: "trading212"
      )
      inflow_entry.entryable ||= Transaction.new(kind: "funds_movement")
      inflow_entry.assign_attributes(
        amount: -transfer_amount,  # negative = inflow
        currency: currency,
        date: date,
        name: "Transfer from #{source_account.name}"
      )
      inflow_entry.save!

      # Create or find Transfer linking them
      transfer = Transfer.find_or_initialize_by(
        inflow_transaction: inflow_entry.entryable,
        outflow_transaction: outflow_entry.entryable
      )
      transfer.status = "confirmed"
      transfer.save!

      Rails.logger.info "Trading212Entry::Processor - Created transfer #{transfer.id} for #{ticker} (#{source_account.name} → #{destination_account.name})"
      transfer
    rescue => e
      Rails.logger.error "Trading212Entry::Processor - Failed to create transfer for #{external_id}: #{e.message}"
      # Don't fail the whole import if transfer creation fails
      nil
    end

    def import_trade
      security = resolve_security
      unless security
        Rails.logger.warn "Trading212Entry::Processor - Could not resolve security for #{data[:ticker]}, skipping trade #{external_id}"
        return nil
      end

      # Determine quantity sign: positive for buy, negative for sell
      qty = trade_quantity

      import_adapter.import_trade(
        external_id: external_id,
        security: security,
        quantity: qty,
        price: trade_price,
        price_currency: share_currency,  # Price is in share currency (e.g., USD)
        amount: amount.abs,  # Total trade value (always positive for import_trade)
        currency: currency,  # Entry amount is in account currency (e.g., EUR)
        date: date,
        name: name,
        source: "trading212"
      )
    end

    def resolve_security
      ticker = data[:ticker].presence
      return nil unless ticker

      @security ||= Security::Resolver.new(ticker).resolve
    end

    def trade_quantity
      shares = data[:shares].to_d
      # Positive for buy, negative for sell
      if data[:action]&.include?("sell")
        -shares.abs
      else
        shares.abs
      end
    end

    def trade_price
      data[:price_per_share].to_d
    end

    def share_currency
      # Price per share is in the share currency (e.g., USD for US stocks)
      parse_currency(data[:share_currency]) || currency
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def account
      @account ||= trading212_account.current_account
    end

    def data
      @data ||= trading212_transaction.with_indifferent_access
    end

    def external_id
      id = data[:id].presence

      # Dividends don't have an ID field - generate a synthetic one
      if id.blank? && dividend?
        # Create unique ID from: ISIN + time + amount
        components = [ data[:isin], data[:time], data[:amount].to_s ].join("_")
        id = Digest::MD5.hexdigest(components)
      end

      raise ArgumentError, "Trading212 transaction missing required field 'id'" unless id
      "trading212_#{id}"
    end

    def dividend?
      data[:action]&.start_with?("Dividend")
    end

    def name
      action = data[:action].presence || "Transaction"

      # For investment orders and dividends, use ticker/stock name
      if investment_order? || dividend?
        ticker = data[:ticker].presence
        stock_name = data[:stock_name].presence
        # For dividends, simplify "Dividend (Dividend)" to just "Dividend"
        display_action = dividend? ? "Dividend" : action
        if ticker.present?
          "#{display_action} #{ticker}"
        elsif stock_name.present?
          "#{display_action} #{stock_name}"
        else
          display_action
        end
      else
        # For regular transactions, use merchant name or action
        merchant_name = data[:merchant_name].presence
        merchant_name.presence || action
      end
    end

    def notes
      action = data[:action].presence
      parts = []

      if investment_order?
        # Investment order details
        parts << "Type: #{action}" if action.present?
        parts << "Ticker: #{data[:ticker]}" if data[:ticker].present?
        parts << "ISIN: #{data[:isin]}" if data[:isin].present?
        parts << "Shares: #{data[:shares]}" if data[:shares].present?
        parts << "Price: #{data[:price_per_share]} #{data[:share_currency]}" if data[:price_per_share].present?
        parts << data[:notes] if data[:notes].present?
      else
        # Regular transaction details
        category = data[:merchant_category].presence
        parts << "Type: #{action}" if action.present?
        parts << "Category: #{category}" if category.present?
      end

      parts.any? ? parts.join(" | ") : nil
    end

    def investment_order?
      %w[Market\ buy Market\ sell Limit\ buy Limit\ sell].include?(data[:action])
    end

    def merchant
      merchant_name = data[:merchant_name].presence
      return nil unless merchant_name.present?

      # Create a stable merchant ID from the merchant name
      merchant_id = Digest::MD5.hexdigest(merchant_name.downcase)

      @merchant ||= begin
        import_adapter.find_or_create_merchant(
          provider_merchant_id: "trading212_merchant_#{merchant_id}",
          name: merchant_name,
          source: "trading212"
        )
      rescue ActiveRecord::RecordInvalid => e
        Rails.logger.error "Trading212Entry::Processor - Failed to create merchant '#{merchant_name}': #{e.message}"
        nil
      end
    end

    def amount
      parsed_amount = case data[:amount]
      when String
        BigDecimal(data[:amount])
      when Numeric
        BigDecimal(data[:amount].to_s)
      else
        BigDecimal("0")
      end

      # Trading 212 CSV conventions:
      # - Card debit: negative amount (expense)
      # - Deposit: positive amount (income)
      # - Market buy: positive amount (money spent on stocks = expense)
      # - Market sell: positive amount (money received from selling = income)
      #
      # Maybe's convention: positive = expense, negative = income
      #
      # For regular transactions, we negate (negative expense -> positive, positive income -> negative)
      # For investment buys, amount is positive and should stay positive (expense)
      # For investment sells, amount is positive but should be negative (income)
      if investment_order?
        if data[:action]&.include?("buy")
          parsed_amount.abs  # Buy = expense (positive)
        else
          -parsed_amount.abs  # Sell = income (negative)
        end
      else
        -parsed_amount
      end
    rescue ArgumentError => e
      Rails.logger.error "Failed to parse Trading212 transaction amount: #{data[:amount].inspect} - #{e.message}"
      raise
    end

    def currency
      parse_currency(data[:currency]) || account&.currency || "EUR"
    end

    def log_invalid_currency(currency_value)
      Rails.logger.warn("Invalid currency code '#{currency_value}' in Trading212 transaction #{external_id}, falling back to account currency")
    end

    def date
      time_value = data[:time]

      case time_value
      when String
        # Trading 212 format: "2026-01-03 15:19:21"
        DateTime.parse(time_value).to_date
      when Integer, Float
        # Unix timestamp
        Time.at(time_value).to_date
      when Time, DateTime
        time_value.to_date
      when Date
        time_value
      else
        Rails.logger.error("Trading212 transaction has invalid time value: #{time_value.inspect}")
        raise ArgumentError, "Invalid time format: #{time_value.inspect}"
      end
    rescue ArgumentError, TypeError => e
      Rails.logger.error("Failed to parse Trading212 transaction time '#{time_value}': #{e.message}")
      raise ArgumentError, "Unable to parse transaction time: #{time_value.inspect}"
    end
end
