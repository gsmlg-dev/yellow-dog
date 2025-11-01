defmodule YellowDog.Dns.RootZone.ManagerTest do
  use ExUnit.Case, async: false

  alias YellowDog.Dns.RootZone.Manager
  alias YellowDog.Dns.RootZone.Hints

  describe "start_link/1 with :hints strategy" do
    test "starts successfully with hints strategy" do
      {:ok, pid} = Manager.start_link(strategy: :hints)

      assert Process.alive?(pid)

      # Clean up
      GenServer.stop(pid)
    end

    test "returns root servers from hints" do
      {:ok, pid} = Manager.start_link(strategy: :hints)

      servers = Manager.get_root_servers()

      assert is_list(servers)
      assert length(servers) == 26

      # Verify format
      Enum.each(servers, fn {name, ip} ->
        assert is_binary(name)
        assert is_tuple(ip)
      end)

      # Clean up
      GenServer.stop(pid)
    end

    test "reports correct strategy" do
      {:ok, pid} = Manager.start_link(strategy: :hints)

      assert Manager.get_strategy() == :hints

      # Clean up
      GenServer.stop(pid)
    end

    test "returns stats for hints strategy" do
      {:ok, pid} = Manager.start_link(strategy: :hints)

      stats = Manager.stats()

      assert stats.strategy == :hints
      assert stats.server_count == 26
      assert stats.ipv4_count == 13
      assert stats.ipv6_count == 13
      assert is_integer(stats.loaded_at)

      # Clean up
      GenServer.stop(pid)
    end
  end

  describe "start_link/1 with :fetch strategy" do
    @tag :integration
    test "starts with fetch strategy and falls back to hints on error" do
      # This will fail to fetch but should fallback to hints
      {:ok, pid} =
        Manager.start_link(
          strategy: :fetch,
          fetch_url: "https://invalid.example.com/root.zone",
          fallback_to_hints: true
        )

      assert Process.alive?(pid)

      # Should still return servers from hints
      servers = Manager.get_root_servers()
      assert is_list(servers)
      assert length(servers) > 0

      # Clean up
      GenServer.stop(pid)
    end

    @tag :integration
    test "reports fetch strategy" do
      {:ok, pid} =
        Manager.start_link(
          strategy: :fetch,
          fallback_to_hints: true
        )

      assert Manager.get_strategy() == :fetch

      # Clean up
      GenServer.stop(pid)
    end

    @tag :integration
    test "includes fetch configuration in stats" do
      {:ok, pid} =
        Manager.start_link(
          strategy: :fetch,
          fetch_interval_hours: 12,
          fallback_to_hints: true
        )

      stats = Manager.stats()

      assert stats.strategy == :fetch
      assert stats.fetch_interval_hours == 12
      assert stats.fallback_to_hints == true
      assert Map.has_key?(stats, :next_fetch_seconds)

      # Clean up
      GenServer.stop(pid)
    end
  end

  describe "start_link/1 with :auth strategy" do
    test "falls back to hints when zone file not found" do
      {:ok, pid} =
        Manager.start_link(
          strategy: :auth,
          zone_file: "/nonexistent/root.zone",
          fallback_to_hints: true
        )

      assert Process.alive?(pid)

      # Should return servers from hints
      servers = Manager.get_root_servers()
      assert is_list(servers)

      # Clean up
      GenServer.stop(pid)
    end

    test "reports auth strategy" do
      {:ok, pid} =
        Manager.start_link(
          strategy: :auth,
          zone_file: "/nonexistent/root.zone",
          fallback_to_hints: true
        )

      assert Manager.get_strategy() == :auth

      # Clean up
      GenServer.stop(pid)
    end

    test "includes zone file in stats" do
      zone_file = "/etc/zones/root.zone"

      {:ok, pid} =
        Manager.start_link(
          strategy: :auth,
          zone_file: zone_file,
          fallback_to_hints: true
        )

      stats = Manager.stats()

      assert stats.strategy == :auth
      assert stats.zone_file == zone_file
      assert stats.fallback_to_hints == true

      # Clean up
      GenServer.stop(pid)
    end
  end

  describe "reload_root_zone/0" do
    test "reloads hints strategy (no-op)" do
      {:ok, pid} = Manager.start_link(strategy: :hints)

      assert :ok = Manager.reload_root_zone()

      # Clean up
      GenServer.stop(pid)
    end

    test "updates loaded_at timestamp on reload" do
      {:ok, pid} = Manager.start_link(strategy: :hints)

      stats_before = Manager.stats()
      :timer.sleep(10)
      Manager.reload_root_zone()
      stats_after = Manager.stats()

      assert stats_after.loaded_at >= stats_before.loaded_at

      # Clean up
      GenServer.stop(pid)
    end
  end

  describe "configuration parsing" do
    test "parses strategy from string" do
      {:ok, pid} = Manager.start_link(strategy: "hints")

      assert Manager.get_strategy() == :hints

      GenServer.stop(pid)
    end

    test "defaults to hints for unknown strategy" do
      {:ok, pid} = Manager.start_link(strategy: "unknown")

      assert Manager.get_strategy() == :hints

      GenServer.stop(pid)
    end

    test "accepts full config map" do
      config = %{
        strategy: :hints,
        fetch_url: "https://example.com/root.zone",
        fetch_interval_hours: 12,
        fallback_to_hints: false,
        zone_file: "/tmp/root.zone"
      }

      {:ok, pid} = Manager.start_link(config: config)

      stats = Manager.stats()
      assert stats.strategy == :hints

      GenServer.stop(pid)
    end
  end

  describe "get_root_servers/0" do
    test "returns same servers as Hints for hints strategy" do
      {:ok, pid} = Manager.start_link(strategy: :hints)

      manager_servers = Manager.get_root_servers()
      hints_servers = Hints.get_root_servers()

      assert manager_servers == hints_servers

      GenServer.stop(pid)
    end

    test "always returns a list" do
      {:ok, pid} = Manager.start_link(strategy: :hints)

      servers = Manager.get_root_servers()

      assert is_list(servers)

      GenServer.stop(pid)
    end
  end
end
