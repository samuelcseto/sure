class SetDefaultAccountTypeForTrading212Accounts < ActiveRecord::Migration[7.2]
  def change
    change_column_default :trading212_accounts, :account_type, from: nil, to: "cash"

    # Update existing records that have null account_type
    reversible do |dir|
      dir.up do
        execute "UPDATE trading212_accounts SET account_type = 'cash' WHERE account_type IS NULL"
      end
    end

    add_index :trading212_accounts, :account_type, if_not_exists: true
  end
end
