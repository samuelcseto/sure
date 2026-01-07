class Trading212Item::Syncer
  attr_reader :trading212_item

  def initialize(trading212_item)
    @trading212_item = trading212_item
  end

  def perform_sync(sync)
    # Phase 1: Import data from Trading 212 API
    sync.update!(status_text: "Importing transactions from Trading 212...") if sync.respond_to?(:status_text)
    trading212_item.import_latest_trading212_data

    # Phase 2: Check account setup status and collect sync statistics
    sync.update!(status_text: "Checking account configuration...") if sync.respond_to?(:status_text)
    total_accounts = trading212_item.trading212_accounts.count
    linked_accounts = trading212_item.trading212_accounts.joins(:account).merge(Account.visible)
    unlinked_accounts = trading212_item.trading212_accounts.left_joins(:account_provider).where(account_providers: { id: nil })

    # Store sync statistics for display
    sync_stats = {
      total_accounts: total_accounts,
      linked_accounts: linked_accounts.count,
      unlinked_accounts: unlinked_accounts.count
    }

    # Set pending_account_setup if there are unlinked accounts
    if unlinked_accounts.any?
      trading212_item.update!(pending_account_setup: true)
      sync.update!(status_text: "#{unlinked_accounts.count} accounts need setup...") if sync.respond_to?(:status_text)
    else
      trading212_item.update!(pending_account_setup: false)
    end

    # Phase 3: Process transactions for linked accounts only
    if linked_accounts.any?
      sync.update!(status_text: "Processing transactions...") if sync.respond_to?(:status_text)
      Rails.logger.info "Trading212Item::Syncer - Processing #{linked_accounts.count} linked accounts"
      trading212_item.process_accounts
      Rails.logger.info "Trading212Item::Syncer - Finished processing accounts"

      # Phase 4: Schedule balance calculations for linked accounts
      sync.update!(status_text: "Calculating balances...") if sync.respond_to?(:status_text)
      trading212_item.schedule_account_syncs(
        parent_sync: sync,
        window_start_date: sync.window_start_date,
        window_end_date: sync.window_end_date
      )
    else
      Rails.logger.info "Trading212Item::Syncer - No linked accounts to process"
    end

    # Store sync statistics in the sync record for status display
    if sync.respond_to?(:sync_stats)
      sync.update!(sync_stats: sync_stats)
    end
  end

  def perform_post_sync
    # no-op
  end
end
