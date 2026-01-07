class Provider::Trading212Adapter < Provider::Base
  include Provider::Syncable
  include Provider::InstitutionMetadata

  # Register this adapter with the factory
  Provider::Factory.register("Trading212Account", self)

  # Define which account types this provider supports
  # Trading 212 supports both cash (Depository) and investment accounts
  def self.supported_account_types
    %w[Depository Investment]
  end

  # Returns connection configurations for this provider
  def self.connection_configs(family:)
    return [] unless family.can_connect_trading212?

    [ {
      key: "trading212",
      name: "Trading 212",
      description: "Import cash transactions from Trading 212",
      can_connect: true,
      new_account_path: ->(accountable_type, return_to) {
        Rails.application.routes.url_helpers.select_accounts_trading212_items_path(
          accountable_type: accountable_type,
          return_to: return_to
        )
      },
      existing_account_path: ->(account_id) {
        Rails.application.routes.url_helpers.select_existing_account_trading212_items_path(
          account_id: account_id
        )
      }
    } ]
  end

  def provider_name
    "trading212"
  end

  # Build a Trading212 provider instance with family-specific credentials
  # @param family [Family] The family to get credentials for (required)
  # @return [Provider::Trading212, nil] Returns nil if credentials are not configured
  def self.build_provider(family: nil)
    return nil unless family.present?

    # Get family-specific credentials
    trading212_item = family.trading212_items.where.not(api_key: nil).first
    return nil unless trading212_item&.credentials_configured?

    Provider::Trading212.new(trading212_item.api_key, trading212_item.api_secret)
  end

  def sync_path
    Rails.application.routes.url_helpers.sync_trading212_item_path(item)
  end

  def item
    provider_account.trading212_item
  end

  def can_delete_holdings?
    false
  end

  # Trading212 only syncs trades, not holdings snapshots
  # Holdings are calculated forward from trade history
  def syncs_holdings?
    false
  end

  def institution_domain
    metadata = provider_account.institution_metadata
    return nil unless metadata.present?

    domain = metadata["domain"]
    url = metadata["url"]

    # Derive domain from URL if missing
    if domain.blank? && url.present?
      begin
        domain = URI.parse(url).host&.gsub(/^www\./, "")
      rescue URI::InvalidURIError
        Rails.logger.warn("Invalid institution URL for Trading212 account #{provider_account.id}: #{url}")
      end
    end

    domain
  end

  def institution_name
    metadata = provider_account.institution_metadata
    return nil unless metadata.present?

    metadata["name"] || item&.institution_name
  end

  def institution_url
    metadata = provider_account.institution_metadata
    return nil unless metadata.present?

    metadata["url"] || item&.institution_url
  end

  def institution_color
    item&.institution_color
  end
end
