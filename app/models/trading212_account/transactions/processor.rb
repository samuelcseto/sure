class Trading212Account::Transactions::Processor
  attr_reader :trading212_account

  def initialize(trading212_account)
    @trading212_account = trading212_account
  end

  def process
    unless trading212_account.raw_transactions_payload.present?
      Rails.logger.info "Trading212Account::Transactions::Processor - No transactions in raw_transactions_payload for trading212_account #{trading212_account.id}"
      return { success: true, total: 0, imported: 0, failed: 0, errors: [] }
    end

    total_count = trading212_account.raw_transactions_payload.count
    Rails.logger.info "Trading212Account::Transactions::Processor - Processing #{total_count} transactions for trading212_account #{trading212_account.id}"

    imported_count = 0
    failed_count = 0
    errors = []

    trading212_account.raw_transactions_payload.each_with_index do |transaction_data, index|
      begin
        result = Trading212Entry::Processor.new(
          transaction_data,
          trading212_account: trading212_account
        ).process

        if result.nil?
          failed_count += 1
          errors << { index: index, transaction_id: transaction_data[:id], error: "No linked account" }
        else
          imported_count += 1
        end
      rescue ArgumentError => e
        failed_count += 1
        transaction_id = transaction_data.try(:[], :id) || transaction_data.try(:[], "id") || "unknown"
        error_message = "Validation error: #{e.message}"
        Rails.logger.error "Trading212Account::Transactions::Processor - #{error_message} (transaction #{transaction_id})"
        errors << { index: index, transaction_id: transaction_id, error: error_message }
      rescue => e
        failed_count += 1
        transaction_id = transaction_data.try(:[], :id) || transaction_data.try(:[], "id") || "unknown"
        error_message = "#{e.class}: #{e.message}"
        Rails.logger.error "Trading212Account::Transactions::Processor - Error processing transaction #{transaction_id}: #{error_message}"
        Rails.logger.error e.backtrace.join("\n")
        errors << { index: index, transaction_id: transaction_id, error: error_message }
      end
    end

    result = {
      success: failed_count == 0,
      total: total_count,
      imported: imported_count,
      failed: failed_count,
      errors: errors
    }

    if failed_count > 0
      Rails.logger.warn "Trading212Account::Transactions::Processor - Completed with #{failed_count} failures out of #{total_count} transactions"
    else
      Rails.logger.info "Trading212Account::Transactions::Processor - Successfully processed #{imported_count} transactions"
    end

    result
  end
end
