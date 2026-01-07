class Trading212Item::Importer
  attr_reader :trading212_item, :trading212_provider

  def initialize(trading212_item, trading212_provider:)
    @trading212_item = trading212_item
    @trading212_provider = trading212_provider
  end

  def import
    Rails.logger.info "Trading212Item::Importer - Starting import for item #{trading212_item.id}"

    # Step 1: Create/update Trading212Accounts (Cash + Investment)
    # This is discovery - we create the account records so users can link them
    accounts = find_or_create_accounts
    accounts_created = accounts.count { |a| a.previously_new_record? }

    Rails.logger.info "Trading212Item::Importer - Accounts discovered: #{accounts.map(&:name).join(', ')} (created: #{accounts_created})"

    # Step 2: Fetch transactions only if at least one account is LINKED
    # Transactions are shared across both accounts - we fetch once and store in both
    transactions_imported = 0

    linked_accounts = trading212_item.trading212_accounts.joins(:account).merge(Account.visible)

    Rails.logger.info "Trading212Item::Importer - Found #{linked_accounts.count} linked accounts"

    if linked_accounts.empty?
      Rails.logger.info "Trading212Item::Importer - No linked accounts yet, skipping transaction fetch"
    else
      # Fetch transactions once for the item (not per-account)
      result = fetch_and_store_all_transactions
      if result[:success]
        transactions_imported = result[:transactions_count]
        Rails.logger.info "Trading212Item::Importer - Fetched #{transactions_imported} transactions"
      else
        Rails.logger.warn "Trading212Item::Importer - Failed to fetch transactions: #{result[:error]}"
      end
    end

    Rails.logger.info "Trading212Item::Importer - Completed import for item #{trading212_item.id}: #{accounts_created} accounts discovered, #{transactions_imported} transactions imported"

    {
      success: true,
      accounts_created: accounts_created,
      accounts_updated: linked_accounts.count,
      transactions_imported: transactions_imported
    }
  rescue => e
    Rails.logger.error "Trading212Item::Importer - Error during import: #{e.class} - #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    { success: false, error: e.message, accounts_imported: 0, transactions_imported: 0 }
  end

  private

    def find_or_create_accounts
      # Fetch real account details from Trading 212 API (single API call)
      Rails.logger.info "Trading212Item::Importer - Fetching account summary from API..."
      @account_summary = trading212_provider.get_account_summary
      Rails.logger.info "Trading212Item::Importer - Account summary: #{@account_summary.inspect}"

      api_account_id = @account_summary[:id].to_s
      currency = @account_summary[:currency] || "EUR"

      # Calculate balances
      spending_balance = trading212_provider.get_spending_balance(@account_summary)
      investment_balance = BigDecimal(@account_summary.dig(:investments, :currentValue).to_s)

      accounts = []

      # Create/update Cash account
      cash_account = find_or_create_typed_account(
        account_id: "#{api_account_id}_cash",
        account_type: "cash",
        name: "Trading 212 Cash",
        currency: currency,
        balance: spending_balance[:balance]
      )
      accounts << cash_account

      # Create/update Investment account
      investment_account = find_or_create_typed_account(
        account_id: "#{api_account_id}_investment",
        account_type: "investment",
        name: "Trading 212 Invest",
        currency: currency,
        balance: investment_balance
      )
      accounts << investment_account

      accounts
    rescue Provider::Trading212::Trading212Error => e
      Rails.logger.error "Trading212Item::Importer - API error in find_or_create_accounts: #{e.message}"
      handle_api_error(e)
      raise
    rescue => e
      Rails.logger.error "Trading212Item::Importer - Unexpected error in find_or_create_accounts: #{e.class} - #{e.message}"
      Rails.logger.error e.backtrace.first(5).join("\n")
      raise
    end

    def find_or_create_typed_account(account_id:, account_type:, name:, currency:, balance:)
      trading212_account = trading212_item.trading212_accounts.find_or_initialize_by(
        account_id: account_id,
        account_type: account_type
      )

      trading212_account.assign_attributes(
        name: name,
        currency: currency,
        current_balance: balance,
        raw_payload: @account_summary,
        provider: "trading212",
        institution_metadata: {
          name: "Trading 212",
          domain: "trading212.com",
          url: "https://www.trading212.com"
        }
      )

      trading212_account.save!
      Rails.logger.info "Trading212Item::Importer - Saved #{account_type} account: #{trading212_account.id} (#{name})"
      trading212_account
    end

    def fetch_and_store_all_transactions
      # Determine sync start date based on existing transactions
      cash_account = trading212_item.trading212_accounts.cash.first
      start_date = determine_sync_start_date(cash_account)
      end_date = Time.current

      Rails.logger.info "Trading212Item::Importer - Fetching transactions from #{start_date} to #{end_date}"

      begin
        transactions_data = trading212_provider.fetch_transactions(
          time_from: start_date,
          time_to: end_date
        )

        return { success: false, transactions_count: 0, error: "No transactions data" } if transactions_data.nil?

        # Separate transactions by type
        cash_transactions = transactions_data.reject { |tx| investment_order?(tx) }
        investment_transactions = transactions_data.select { |tx| investment_order?(tx) }

        Rails.logger.info "Trading212Item::Importer - Found #{cash_transactions.count} cash transactions, #{investment_transactions.count} investment orders"

        # Store in respective accounts
        # Cash account: regular transactions (deposits, card debits, dividends, etc.)
        # Investment account: only investment orders (trades)
        # The entry processor will create Transfers between accounts for investment orders
        cash_account = trading212_item.trading212_accounts.cash.first
        investment_account = trading212_item.trading212_accounts.investment.first

        # Cash account gets regular transactions including dividends
        cash_count = store_transactions(cash_account, cash_transactions) if cash_account

        # Investment account gets only investment orders (for trade tracking + transfer creation)
        investment_count = store_transactions(investment_account, investment_transactions) if investment_account

        # Update balances
        update_account_balances

        { success: true, transactions_count: (cash_count || 0) + (investment_count || 0) }
      rescue Provider::Trading212::Trading212Error => e
        handle_api_error(e)
        { success: false, transactions_count: 0, error: e.message }
      rescue => e
        Rails.logger.error "Trading212Item::Importer - Unexpected error fetching transactions: #{e.class} - #{e.message}"
        { success: false, transactions_count: 0, error: e.message }
      end
    end

    def investment_order?(tx)
      action = tx[:action] || tx.with_indifferent_access[:action]
      %w[Market\ buy Market\ sell Limit\ buy Limit\ sell].include?(action)
    end

    # Get or generate a unique ID for a transaction
    # Dividends don't have IDs, so we generate synthetic ones
    def transaction_id(tx)
      tx = tx.with_indifferent_access
      id = tx[:id].presence

      # Dividends don't have IDs - generate synthetic one from ISIN + time + amount
      if id.blank? && tx[:action]&.start_with?("Dividend")
        components = [ tx[:isin], tx[:time], tx[:amount].to_s ].join("_")
        id = "dividend_#{Digest::MD5.hexdigest(components)}"
      end

      id
    end

    def store_transactions(trading212_account, transactions_data)
      return 0 if transactions_data.blank? || trading212_account.nil?

      existing_transactions = trading212_account.raw_transactions_payload.to_a
      existing_ids = existing_transactions.map { |tx| transaction_id(tx) }.to_set

      # Filter to new transactions only
      new_transactions = transactions_data.select do |tx|
        tx_id = transaction_id(tx)
        tx_id.present? && !existing_ids.include?(tx_id)
      end

      if new_transactions.any?
        Rails.logger.info "Trading212Item::Importer - Storing #{new_transactions.count} new transactions in #{trading212_account.account_type} account"
        trading212_account.upsert_trading212_transactions_snapshot!(existing_transactions + new_transactions)
      else
        Rails.logger.info "Trading212Item::Importer - No new transactions to store in #{trading212_account.account_type} account"
      end

      new_transactions.count
    end

    def update_account_balances
      # Fetch real balance from API
      begin
        account_summary = trading212_provider.get_account_summary
        spending_balance = trading212_provider.get_spending_balance(account_summary)
        investment_balance = BigDecimal(account_summary.dig(:investments, :currentValue).to_s)

        # Update cash account
        cash_account = trading212_item.trading212_accounts.cash.first
        if cash_account
          cash_account.update!(
            currency: spending_balance[:currency],
            current_balance: spending_balance[:balance],
            raw_payload: account_summary
          )
        end

        # Update investment account
        investment_account = trading212_item.trading212_accounts.investment.first
        if investment_account
          investment_account.update!(
            currency: account_summary[:currency],
            current_balance: investment_balance,
            raw_payload: account_summary
          )
        end
      rescue Provider::Trading212::Trading212Error => e
        Rails.logger.warn "Trading212Item::Importer - Failed to fetch balance from API: #{e.message}"
        # Don't fail the import if balance fetch fails
      end
    end

    def determine_sync_start_date(trading212_account)
      if trading212_account&.raw_transactions_payload.to_a.any?
        # Account has been synced before - use last_synced_at with buffer
        trading212_item.last_synced_at ? trading212_item.last_synced_at - 7.days : 3.months.ago
      else
        # First sync - always use 1 year (max supported by Trading 212 API)
        1.year.ago
      end
    end

    def handle_api_error(error)
      if error.error_type == :unauthorized || error.error_type == :access_forbidden
        trading212_item.update!(status: :requires_update)
      end
      Rails.logger.error "Trading212Item::Importer - Trading 212 API error: #{error.message}"
    end
end
