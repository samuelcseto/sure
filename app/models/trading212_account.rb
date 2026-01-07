class Trading212Account < ApplicationRecord
  include CurrencyNormalizable

  ACCOUNT_TYPES = %w[cash investment].freeze

  belongs_to :trading212_item

  # New association through account_providers
  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider, source: :account
  has_one :linked_account, through: :account_provider, source: :account

  validates :name, :currency, presence: true
  validates :account_type, inclusion: { in: ACCOUNT_TYPES }

  scope :cash, -> { where(account_type: "cash") }
  scope :investment, -> { where(account_type: "investment") }

  def cash?
    account_type == "cash"
  end

  def investment?
    account_type == "investment"
  end

  # Helper to get account using account_providers system
  def current_account
    account
  end

  def upsert_trading212_snapshot!(account_snapshot)
    snapshot = account_snapshot.with_indifferent_access

    update!(
      current_balance: snapshot[:balance] || snapshot[:current_balance],
      currency: parse_currency(snapshot[:currency]) || "EUR",
      name: snapshot[:name],
      account_id: snapshot[:id]&.to_s,
      account_status: snapshot[:status],
      provider: "trading212",
      institution_metadata: {
        name: "Trading 212",
        domain: "trading212.com"
      },
      raw_payload: account_snapshot
    )
  end

  def upsert_trading212_transactions_snapshot!(transactions_snapshot)
    assign_attributes(
      raw_transactions_payload: transactions_snapshot
    )

    save!
  end

  private

    def log_invalid_currency(currency_value)
      Rails.logger.warn("Invalid currency code '#{currency_value}' for Trading212 account #{id}, defaulting to USD")
    end
end
