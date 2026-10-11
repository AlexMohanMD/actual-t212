class CreateSyncStates < ActiveRecord::Migration[8.1]
  def change
    create_table :sync_states do |t|
      t.datetime :last_synced_at
      t.decimal :last_balance, precision: 12, scale: 2

      t.timestamps
    end
  end
end
