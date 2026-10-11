require "test_helper"

class RecurringScheduleTest < ActiveSupport::TestCase
  test "default schedule for sync_all is daily (every day)" do
    with_env("SYNC_FREQUENCY" => nil, "SYNC_SCHEDULE" => nil) do
      tasks = SolidQueue::Configuration.new.send(:recurring_tasks)
      sync_task = tasks.find { |t| t.key == "sync_all" }

      assert_not_nil sync_task
      assert_equal "SyncAllJob", sync_task.class_name
      assert_equal "every day", sync_task.schedule
      assert sync_task.valid?
    end
  end

  test "sync_all schedule is configurable via SYNC_FREQUENCY" do
    with_env("SYNC_FREQUENCY" => "every 6 hours") do
      tasks = SolidQueue::Configuration.new.send(:recurring_tasks)
      sync_task = tasks.find { |t| t.key == "sync_all" }

      assert_not_nil sync_task
      assert_equal "every 6 hours", sync_task.schedule
      assert sync_task.valid?
    end
  end

  test "sync_all schedule supports friendly frequency names" do
    with_env("SYNC_FREQUENCY" => "hourly") do
      tasks = SolidQueue::Configuration.new.send(:recurring_tasks)
      sync_task = tasks.find { |t| t.key == "sync_all" }

      assert_not_nil sync_task
      assert_equal "every hour", sync_task.schedule
      assert sync_task.valid?
    end
  end

  private

  def with_env(vars)
    original = vars.keys.to_h { |k| [ k, ENV[k] ] }
    vars.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    original.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end
end
