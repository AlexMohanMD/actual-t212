class CreateTransactions < ActiveRecord::Migration[8.1]
  def change
    create_table :transactions do |t|
      t.string :payee
      t.string :notes
      t.decimal :amount, precision: 12, scale: 2
      t.boolean :synced_to_actual
      t.datetime :occurred_at

      t.timestamps
    end
  end
end
