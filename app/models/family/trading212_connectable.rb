module Family::Trading212Connectable
  extend ActiveSupport::Concern

  included do
    has_many :trading212_items, dependent: :destroy
  end

  def can_connect_trading212?
    # Families can configure their own Trading212 credentials
    true
  end

  def create_trading212_item!(api_key:, api_secret:, item_name: nil)
    trading212_item = trading212_items.create!(
      name: item_name || "Trading 212 Connection",
      api_key: api_key,
      api_secret: api_secret
    )

    trading212_item.sync_later

    trading212_item
  end

  def has_trading212_credentials?
    trading212_items.where.not(api_key: nil).where.not(api_secret: nil).exists?
  end
end
