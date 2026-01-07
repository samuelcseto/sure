class Trading212ItemsController < ApplicationController
  before_action :set_trading212_item, only: [ :show, :edit, :update, :destroy, :sync, :setup_accounts, :complete_account_setup ]

  def index
    @trading212_items = Current.family.trading212_items.ordered
  end

  def show
  end

  def new
    @trading212_item = Current.family.trading212_items.build
  end

  def edit
  end

  def create
    @trading212_item = Current.family.trading212_items.build(trading212_item_params)
    @trading212_item.name ||= "Trading 212 Connection"

    if @trading212_item.save
      # Auto-discover accounts by triggering initial sync
      @trading212_item.sync_later

      if turbo_frame_request?
        flash.now[:notice] = t(".success", default: "Successfully configured Trading 212. Syncing accounts...")
        @trading212_items = Current.family.trading212_items.ordered
        render turbo_stream: [
          turbo_stream.replace(
            "trading212-providers-panel",
            partial: "settings/providers/trading212_panel",
            locals: { trading212_items: @trading212_items }
          ),
          *flash_notification_stream_items
        ]
      else
        redirect_to settings_providers_path, notice: t(".success", default: "Successfully configured Trading 212. Syncing accounts..."), status: :see_other
      end
    else
      @error_message = @trading212_item.errors.full_messages.join(", ")

      if turbo_frame_request?
        render turbo_stream: turbo_stream.replace(
          "trading212-providers-panel",
          partial: "settings/providers/trading212_panel",
          locals: { error_message: @error_message }
        ), status: :unprocessable_entity
      else
        redirect_to settings_providers_path, alert: @error_message, status: :unprocessable_entity
      end
    end
  end

  def update
    if @trading212_item.update(trading212_item_params)
      if turbo_frame_request?
        flash.now[:notice] = t(".success", default: "Successfully updated Trading 212 configuration.")
        @trading212_items = Current.family.trading212_items.ordered
        render turbo_stream: [
          turbo_stream.replace(
            "trading212-providers-panel",
            partial: "settings/providers/trading212_panel",
            locals: { trading212_items: @trading212_items }
          ),
          *flash_notification_stream_items
        ]
      else
        redirect_to settings_providers_path, notice: t(".success"), status: :see_other
      end
    else
      @error_message = @trading212_item.errors.full_messages.join(", ")

      if turbo_frame_request?
        render turbo_stream: turbo_stream.replace(
          "trading212-providers-panel",
          partial: "settings/providers/trading212_panel",
          locals: { error_message: @error_message }
        ), status: :unprocessable_entity
      else
        redirect_to settings_providers_path, alert: @error_message, status: :unprocessable_entity
      end
    end
  end

  def destroy
    @trading212_item.destroy_later
    redirect_to settings_providers_path, notice: t(".success", default: "Scheduled Trading 212 connection for deletion.")
  end

  def sync
    unless @trading212_item.syncing?
      @trading212_item.sync_later
    end

    respond_to do |format|
      format.html { redirect_back_or_to accounts_path }
      format.json { head :ok }
    end
  end

  # Collection actions for account linking flow
  # Trading 212 has a simplified flow since there's one account per API key

  def preload_accounts
    # Trading 212 creates accounts automatically during sync
    redirect_to settings_providers_path, notice: "Accounts will be available after first sync"
  end

  def select_accounts
    @accountable_type = params[:accountable_type]
    @return_to = params[:return_to]
    @trading212_items = Current.family.trading212_items.active.ordered
    # For Trading 212, we show available accounts from existing items
  end

  def link_accounts
    # Link Trading 212 accounts to internal accounts
    redirect_to settings_providers_path, notice: "Account linking initiated"
  end

  def select_existing_account
    @account_id = params[:account_id]
    @trading212_items = Current.family.trading212_items.active.ordered
  end

  def link_existing_account
    # Link an existing internal account to a Trading 212 account
    redirect_to settings_providers_path, notice: "Account linked"
  end

  def setup_accounts
    @trading212_accounts = @trading212_item.trading212_accounts.left_joins(:account_provider)
                                           .where(account_providers: { id: nil })
  end

  def complete_account_setup
    account_ids = params[:account_ids] || []
    created_accounts = []

    begin
      ActiveRecord::Base.transaction do
        account_ids.each do |trading212_account_id|
          trading212_account = @trading212_item.trading212_accounts.find_by(id: trading212_account_id)
          next unless trading212_account

          # Skip if already linked
          if trading212_account.account_provider.present?
            Rails.logger.info("Trading212 account #{trading212_account_id} already linked, skipping")
            next
          end

          # Create account with correct type based on trading212_account.account_type
          accountable_type, accountable_attributes, initial_balance = account_type_for(trading212_account)

          # Skip initial sync - provider sync will handle balance creation with correct currency
          account = Account.create_and_sync(
            {
              family: Current.family,
              name: trading212_account.name,
              balance: initial_balance,
              currency: trading212_account.currency || "EUR",
              accountable_type: accountable_type,
              accountable_attributes: accountable_attributes
            },
            skip_initial_sync: true
          )

          # Link account to trading212_account via account_providers join table
          AccountProvider.create!(
            account: account,
            provider: trading212_account
          )

          created_accounts << account
        end
      end
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved => e
      Rails.logger.error("Trading 212 account setup failed: #{e.class} - #{e.message}")
      flash[:alert] = "Account creation failed: #{e.message}"
      redirect_to accounts_path, status: :see_other
      return
    end

    # Trigger sync to process transactions
    @trading212_item.sync_later if created_accounts.any?

    if created_accounts.any?
      redirect_to accounts_path, notice: "Successfully created #{created_accounts.count} account(s)"
    else
      redirect_to accounts_path, notice: "No new accounts were created"
    end
  end

  def account_type_for(trading212_account)
    # Both accounts start with 0 balance - funds come in via synced transactions
    if trading212_account.investment?
      [ "Investment", { subtype: "brokerage" }, 0 ]
    else
      [ "Depository", {}, 0 ]
    end
  end

  private

    def set_trading212_item
      @trading212_item = Current.family.trading212_items.find(params[:id])
    end

    def trading212_item_params
      params.require(:trading212_item).permit(
        :name,
        :api_key,
        :api_secret
      )
    end
end
