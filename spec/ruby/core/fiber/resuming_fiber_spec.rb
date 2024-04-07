require_relative '../../spec_helper'

ruby_version_is "3.4" do
  describe "Fiber#resuming_fiber" do
    it "returns the Fiber that has resumed the Fiber" do
      root_fiber = Fiber.current
      f1 = Fiber.new { root_fiber.transfer }
      f2 = Fiber.new { f1.resume }
      f2.transfer
      f1.resuming_fiber.should == nil
      f2.resuming_fiber.should == f1
    end
  end
end

