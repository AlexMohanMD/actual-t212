require "test_helper"

class TransactionTest < ActiveSupport::TestCase
  test "scopes filter by synced_to_actual" do
    Transaction.delete_all

    unsynced1 = Transaction.create!(payee: "Coffee", amount: -3.50, synced_to_actual: false)
    unsynced2 = Transaction.create!(payee: "Groceries", amount: -25.00, synced_to_actual: nil)
    synced = Transaction.create!(payee: "Salary", amount: 2000.00, synced_to_actual: true)

    assert_includes Transaction.unsynced, unsynced1
    assert_includes Transaction.unsynced, unsynced2
    assert_not_includes Transaction.unsynced, synced

    assert_includes Transaction.synced, synced
    assert_not_includes Transaction.synced, unsynced1
    assert_not_includes Transaction.synced, unsynced2
  end
end
