require "test_helper"

class SyncAllJobTest < ActiveJob::TestCase
  test "enqueues sync_all_job in default queue" do
    assert_enqueued_with(job: SyncAllJob, queue: "default") do
      SyncAllJob.perform_later
    end
  end

  test "performs sync:all rake task" do
    original_sync_new = SyncWithBalance.method(:new)
    original_actual_call = ActualClient.method(:call)

    sync_called = false
    actual_called = false

    SyncWithBalance.define_singleton_method(:new) do
      Object.new.tap do |obj|
        obj.define_singleton_method(:call) { sync_called = true }
      end
    end

    ActualClient.define_singleton_method(:call) do
      actual_called = true
      { synced_count: 5, added: [], updated: [] }
    end

    begin
      assert_output(/Syncing transactions from Trading212/) do
        SyncAllJob.perform_now
      end

      assert sync_called, "Expected SyncWithBalance.new.call to be executed"
      assert actual_called, "Expected ActualClient.call to be executed"
    ensure
      SyncWithBalance.define_singleton_method(:new, original_sync_new)
      ActualClient.define_singleton_method(:call, original_actual_call)
    end
  end
end
