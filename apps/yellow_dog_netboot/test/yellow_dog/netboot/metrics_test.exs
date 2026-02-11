defmodule YellowDog.Netboot.MetricsTest do
  use ExUnit.Case, async: false

  alias YellowDog.Netboot.Metrics

  setup do
    Metrics.init()
    Metrics.reset()
    :ok
  end

  describe "init/0" do
    test "creates ETS table with zero counters" do
      assert Metrics.get(:tftp_requests_accepted) == 0
      assert Metrics.get(:tftp_transfers_completed) == 0
      assert Metrics.get(:tftp_bytes_transferred) == 0
    end

    test "is idempotent" do
      Metrics.increment(:tftp_requests_accepted)
      Metrics.init()
      assert Metrics.get(:tftp_requests_accepted) == 1
    end
  end

  describe "increment/2" do
    test "increments counter by 1 by default" do
      Metrics.increment(:tftp_requests_accepted)
      assert Metrics.get(:tftp_requests_accepted) == 1
    end

    test "increments counter by specified amount" do
      Metrics.increment(:tftp_bytes_transferred, 1024)
      assert Metrics.get(:tftp_bytes_transferred) == 1024
    end

    test "accumulates multiple increments" do
      Metrics.increment(:tftp_transfers_started)
      Metrics.increment(:tftp_transfers_started)
      Metrics.increment(:tftp_transfers_started)
      assert Metrics.get(:tftp_transfers_started) == 3
    end
  end

  describe "all/0" do
    test "returns all counters as a map" do
      Metrics.increment(:tftp_requests_accepted, 5)
      Metrics.increment(:tftp_transfers_completed, 3)

      result = Metrics.all()

      assert result.tftp_requests_accepted == 5
      assert result.tftp_transfers_completed == 3
      assert result.tftp_bytes_transferred == 0
      assert Map.has_key?(result, :devices_discovered)
      assert Map.has_key?(result, :boot_scripts_rendered)
    end
  end

  describe "reset/0" do
    test "resets all counters to zero" do
      Metrics.increment(:tftp_requests_accepted, 10)
      Metrics.increment(:tftp_bytes_transferred, 999)
      Metrics.reset()

      assert Metrics.get(:tftp_requests_accepted) == 0
      assert Metrics.get(:tftp_bytes_transferred) == 0
    end
  end

  describe "counter_names/0" do
    test "returns all counter names" do
      names = Metrics.counter_names()
      assert :tftp_requests_accepted in names
      assert :tftp_transfers_completed in names
      assert :tftp_bytes_transferred in names
      assert :devices_discovered in names
      assert :boot_scripts_rendered in names
      assert :tftp_transfers_failed in names
      assert :tftp_requests_rejected in names
      assert :tftp_transfers_started in names
      assert length(names) == 8
    end
  end

  describe "resilience when ETS table is missing" do
    test "get returns 0 when table is deleted" do
      :ets.delete(Metrics)
      assert Metrics.get(:tftp_requests_accepted) == 0
      # Re-init for other tests
      Metrics.init()
    end

    test "increment is safe when table is deleted" do
      :ets.delete(Metrics)
      assert Metrics.increment(:tftp_requests_accepted) == :ok
      Metrics.init()
    end

    test "reset is safe when table is deleted" do
      :ets.delete(Metrics)
      assert Metrics.reset() == :ok
      Metrics.init()
    end
  end

  describe "all counter types" do
    test "devices_discovered counter works" do
      Metrics.increment(:devices_discovered, 7)
      assert Metrics.get(:devices_discovered) == 7
    end

    test "boot_scripts_rendered counter works" do
      Metrics.increment(:boot_scripts_rendered, 3)
      assert Metrics.get(:boot_scripts_rendered) == 3
    end

    test "tftp_transfers_failed counter works" do
      Metrics.increment(:tftp_transfers_failed, 2)
      assert Metrics.get(:tftp_transfers_failed) == 2
    end

    test "tftp_requests_rejected counter works" do
      Metrics.increment(:tftp_requests_rejected, 4)
      assert Metrics.get(:tftp_requests_rejected) == 4
    end
  end
end
