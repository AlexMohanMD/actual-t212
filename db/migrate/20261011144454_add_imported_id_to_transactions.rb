class AddImportedIdToTransactions < ActiveRecord::Migration[8.1]
  def change
    add_column :transactions, :imported_id, :string
    add_index :transactions, :imported_id, unique: true
  end
end
