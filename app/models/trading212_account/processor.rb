class Trading212Account::Processor
  include CurrencyNormalizable

  attr_reader :trading212_account

  def initialize(trading212_account)
    @trading212_account = trading212_account
  end

  def process
    unless trading212_account.current_account.present?
      Rails.logger.info "Trading212Account::Processor - No linked account for trading212_account #{trading212_account.id}, skipping processing"
      return
    end

    Rails.logger.info "Trading212Account::Processor - Processing trading212_account #{trading212_account.id} (account #{trading212_account.account_id})"

    begin
      process_account!
    rescue StandardError => e
      Rails.logger.error "Trading212Account::Processor - Failed to process account #{trading212_account.id}: #{e.message}"
      Rails.logger.error "Backtrace: #{e.backtrace.join("\n")}"
      raise
    end

    process_transactions
  end

  private

    def process_account!
      if trading212_account.current_account.blank?
        Rails.logger.error("Trading212 account #{trading212_account.id} has no associated Account")
        return
      end

      account = trading212_account.current_account
      current_balance = trading212_account.current_balance || 0

      # Normalize currency with fallback chain
      currency = parse_currency(trading212_account.currency) || account.currency || "EUR"

      # Update account balance
      account.update!(
        balance: current_balance,
        cash_balance: current_balance,
        currency: currency
      )

      # Set opening anchor if we have transactions (balance starts at 0)
      set_opening_anchor_from_transactions(account, current_balance)
    end

    def set_opening_anchor_from_transactions(account, current_balance)
      transactions = trading212_account.raw_transactions_payload.to_a
      return if transactions.empty?

      # Find oldest transaction date for the opening anchor
      oldest_date = transactions.map do |tx|
        date_str = tx.with_indifferent_access[:time] || tx.with_indifferent_access[:date]
        next nil unless date_str.present?
        Date.parse(date_str.to_s) rescue nil
      end.compact.min

      return unless oldest_date.present?

      # Set opening anchor one day before oldest transaction with balance of 0
      opening_date = oldest_date - 1.day

      Rails.logger.info "Trading212Account::Processor - Setting opening anchor: balance=0, date=#{opening_date}"

      account.set_opening_anchor_balance(balance: 0, date: opening_date)
    end

    def process_transactions
      Trading212Account::Transactions::Processor.new(trading212_account).process
    rescue => e
      Rails.logger.error "Trading212Account::Processor - Error processing transactions: #{e.message}"
    end
end
