defmodule YellowDog.Console.ServiceHelperTest do
  use ExUnit.Case, async: true

  alias YellowDog.Console.ServiceHelper

  describe "safe_call/3" do
    test "calls function when module is loaded" do
      result = ServiceHelper.safe_call(Enum, fn -> Enum.sum([1, 2, 3]) end, 0)
      assert result == 6
    end

    test "returns default when module is not loaded" do
      result = ServiceHelper.safe_call(NonExistentModule, fn -> raise "boom" end, :default)
      assert result == :default
    end

    test "returns default when function raises" do
      result = ServiceHelper.safe_call(Enum, fn -> raise "boom" end, :fallback)
      assert result == :fallback
    end

    test "returns default when function exits" do
      result = ServiceHelper.safe_call(Enum, fn -> exit(:shutdown) end, :fallback)
      assert result == :fallback
    end

    test "returns default when function throws" do
      result = ServiceHelper.safe_call(Enum, fn -> throw(:oops) end, :fallback)
      assert result == :fallback
    end

    test "defaults to nil when no default provided" do
      result = ServiceHelper.safe_call(NonExistentModule, fn -> :ok end)
      assert result == nil
    end

    test "returns complex default values" do
      default = %{leases: [], stats: %{total: 0}}
      result = ServiceHelper.safe_call(NonExistentModule, fn -> :ok end, default)
      assert result == default
    end
  end

  describe "service_running?/1" do
    test "returns true for registered process" do
      # The test process itself isn't registered, but we can register one
      {:ok, pid} = Agent.start_link(fn -> :ok end, name: :test_service_helper_agent)
      assert ServiceHelper.service_running?(:test_service_helper_agent) == true
      Agent.stop(pid)
    end

    test "returns false for unregistered process name" do
      assert ServiceHelper.service_running?(:nonexistent_service_process) == false
    end

    test "returns false after process stops" do
      {:ok, pid} = Agent.start_link(fn -> :ok end, name: :test_service_helper_temp)
      assert ServiceHelper.service_running?(:test_service_helper_temp) == true
      Agent.stop(pid)
      assert ServiceHelper.service_running?(:test_service_helper_temp) == false
    end
  end
end
