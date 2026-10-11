namespace :actual do
  desc "Sync unsynced transactions from DB to Actual Budget"
  task sync: :environment do
    result = ActualClient.call
    puts "Synced #{result[:synced_count]} transactions to Actual Budget."
    puts "Added: #{result[:added].size}, Updated: #{result[:updated].size}" if result[:added].present? || result[:updated].present?
  end
end

namespace :sync do
  desc "Run Trading212 sync and then sync to Actual Budget"
  task all: :environment do
    puts "Syncing transactions from Trading212..."
    SyncWithBalance.new.call
    puts "Syncing unsynced transactions to Actual Budget..."
    result = ActualClient.call
    puts "Synced #{result[:synced_count]} transactions to Actual Budget."
  end
end
