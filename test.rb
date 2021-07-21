
require_relative 'test/fiber/scheduler'

thread = Thread.new do
  scheduler = SleepingUnblockScheduler.new
  Fiber.set_scheduler scheduler

  Fiber.schedule do
    thread = Thread.new{sleep(0.01)}

    puts "Time to hang."
    thread.join
    puts "I'm okay now."
  end
end

thread.join
