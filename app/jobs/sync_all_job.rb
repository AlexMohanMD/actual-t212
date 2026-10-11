class SyncAllJob < ApplicationJob
  queue_as :default

  def perform
    require "rake"
    Rails.application.load_tasks unless Rake::Task.task_defined?("sync:all")
    Rake::Task["sync:all"].reenable
    Rake::Task["sync:all"].invoke
  end
end
