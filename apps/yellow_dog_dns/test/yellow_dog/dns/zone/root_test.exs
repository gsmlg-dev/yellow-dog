defmodule YellowDog.Dns.Zone.RootTest do
  @moduledoc """
  Comprehensive unit tests for YellowDog.Dns.Zone.Root.

  Tests cover:
  - GenServer lifecycle (start/stop)
  - Root hints configuration
  - Resolve behavior (referral to root servers)
  - Reload functionality
  - Stats tracking
  """
  use ExUnit.Case, async: false

  alias YellowDog.Dns.Zone.Root

  @default_root_servers [
    {{198, 41, 0, 4}, 53},
    {{199, 9, 14, 201}, 53},
    {{192, 33, 4, 12}, 53},
    {{199, 7, 91, 13}, 53},
    {{192, 203, 230, 10}, 53},
    {{192, 5, 5, 241}, 53},
    {{192, 112, 36, 4}, 53},
    {{198, 97, 190, 53}, 53},
    {{192, 36, 148, 17}, 53},
    {{192, 58, 128, 30}, 53},
    {{193, 0, 14, 129}, 53},
    {{199, 7, 83, 42}, 53},
    {{202, 12, 27, 33}, 53}
  ]

  # Start registry once for all tests in this module
  setup_all do
    registry_name = YellowDog.Dns.ZoneRegistry

    # Start registry if not running
    registry_pid =
      case Process.whereis(registry_name) do
        nil ->
          {:ok, pid} = Registry.start_link(keys: :unique, name: registry_name)
          pid

        pid ->
          pid
      end

    # Small delay to ensure registry is ready
    Process.sleep(10)

    {:ok, registry_pid: registry_pid}
  end

  setup do
    # Generate unique view name for test isolation
    test_ref = :erlang.unique_integer([:positive])
    view_name = "test_view_#{test_ref}"
    zone_name = ".test#{test_ref}"

    # Verify registry is available
    registry_name = YellowDog.Dns.ZoneRegistry

    case Process.whereis(registry_name) do
      nil ->
        # Re-start if needed (rare case where registry died)
        {:ok, _} = Registry.start_link(keys: :unique, name: registry_name)
        Process.sleep(10)

      _pid ->
        :ok
    end

    {:ok, view_name: view_name, zone_name: zone_name}
  end

  describe "start_link/1" do
    test "starts with default options", %{view_name: view_name} do
      {:ok, pid} = Root.start_link(name: ".", view_name: view_name)

      assert is_pid(pid)
      assert Process.alive?(pid)

      GenServer.stop(pid)
    end

    test "uses default zone name '.' when not specified", %{view_name: view_name} do
      {:ok, pid} = Root.start_link(view_name: view_name)

      assert Root.get_name(pid) == "."

      GenServer.stop(pid)
    end

    test "uses default view name 'default' when not specified" do
      # Use a unique ref to avoid conflicts
      test_ref = :erlang.unique_integer([:positive])

      {:ok, pid} = Root.start_link(name: ".test#{test_ref}")

      assert Root.get_view(pid) == "default"

      GenServer.stop(pid)
    end

    test "accepts custom root servers", %{view_name: view_name} do
      custom_servers = [{{8, 8, 8, 8}, 53}, {{1, 1, 1, 1}, 53}]

      {:ok, pid} = Root.start_link(name: ".", view_name: view_name, root_servers: custom_servers)

      assert Root.get_root_servers(pid) == custom_servers

      GenServer.stop(pid)
    end

    test "registers with ZoneRegistry", %{view_name: view_name} do
      {:ok, pid} = Root.start_link(name: ".", view_name: view_name)

      # Verify registration via Registry lookup
      assert [{^pid, _}] = Registry.lookup(YellowDog.Dns.ZoneRegistry, {view_name, :root, "."})

      GenServer.stop(pid)
    end
  end

  describe "get_name/1" do
    test "returns the zone name", %{view_name: view_name} do
      {:ok, pid} = Root.start_link(name: ".", view_name: view_name)

      assert Root.get_name(pid) == "."

      GenServer.stop(pid)
    end

    test "returns custom zone name if provided", %{view_name: view_name} do
      {:ok, pid} = Root.start_link(name: ".custom", view_name: view_name)

      assert Root.get_name(pid) == ".custom"

      GenServer.stop(pid)
    end
  end

  describe "get_view/1" do
    test "returns the view name", %{view_name: view_name} do
      {:ok, pid} = Root.start_link(name: ".", view_name: view_name)

      assert Root.get_view(pid) == view_name

      GenServer.stop(pid)
    end
  end

  describe "get_root_servers/1" do
    test "returns default root servers when not configured", %{view_name: view_name} do
      {:ok, pid} = Root.start_link(name: ".", view_name: view_name)

      servers = Root.get_root_servers(pid)

      assert length(servers) == 13
      assert servers == @default_root_servers

      GenServer.stop(pid)
    end

    test "returns custom root servers when configured", %{view_name: view_name} do
      custom_servers = [{{10, 0, 0, 1}, 53}]

      {:ok, pid} = Root.start_link(name: ".", view_name: view_name, root_servers: custom_servers)

      assert Root.get_root_servers(pid) == custom_servers

      GenServer.stop(pid)
    end

    test "returns empty list when configured with empty servers", %{view_name: view_name} do
      {:ok, pid} = Root.start_link(name: ".", view_name: view_name, root_servers: [])

      assert Root.get_root_servers(pid) == []

      GenServer.stop(pid)
    end
  end

  describe "resolve/2" do
    test "returns referral to root servers", %{view_name: view_name} do
      {:ok, pid} = Root.start_link(name: ".", view_name: view_name)

      # Any query should return referral to root servers
      query = %{name: "example.com", type: :a}
      result = Root.resolve(pid, query)

      assert {:referral, servers} = result
      assert length(servers) == 13

      GenServer.stop(pid)
    end

    test "increments query count on each resolve", %{view_name: view_name} do
      {:ok, pid} = Root.start_link(name: ".", view_name: view_name)

      # Initial query count is 0
      stats1 = Root.stats(pid)
      assert stats1.query_count == 0

      # First query
      Root.resolve(pid, %{name: "example.com"})
      stats2 = Root.stats(pid)
      assert stats2.query_count == 1

      # Second query
      Root.resolve(pid, %{name: "test.org"})
      stats3 = Root.stats(pid)
      assert stats3.query_count == 2

      GenServer.stop(pid)
    end

    test "referral contains custom root servers when configured", %{view_name: view_name} do
      custom_servers = [{{8, 8, 8, 8}, 53}]

      {:ok, pid} = Root.start_link(name: ".", view_name: view_name, root_servers: custom_servers)

      {:referral, servers} = Root.resolve(pid, %{name: "example.com"})
      assert servers == custom_servers

      GenServer.stop(pid)
    end
  end

  describe "reload/2" do
    test "updates root servers", %{view_name: view_name} do
      {:ok, pid} = Root.start_link(name: ".", view_name: view_name)

      # Initial servers are defaults
      assert length(Root.get_root_servers(pid)) == 13

      # Reload with new servers
      new_servers = [{{8, 8, 8, 8}, 53}]
      assert :ok = Root.reload(pid, root_servers: new_servers)

      assert Root.get_root_servers(pid) == new_servers

      GenServer.stop(pid)
    end

    test "keeps existing servers when reload config is empty", %{view_name: view_name} do
      custom_servers = [{{10, 0, 0, 1}, 53}]
      {:ok, pid} = Root.start_link(name: ".", view_name: view_name, root_servers: custom_servers)

      assert :ok = Root.reload(pid, [])

      # Should still have the original custom servers
      assert Root.get_root_servers(pid) == custom_servers

      GenServer.stop(pid)
    end

    test "can set root servers to empty list", %{view_name: view_name} do
      {:ok, pid} = Root.start_link(name: ".", view_name: view_name)

      assert length(Root.get_root_servers(pid)) == 13

      assert :ok = Root.reload(pid, root_servers: [])

      assert Root.get_root_servers(pid) == []

      GenServer.stop(pid)
    end
  end

  describe "stats/1" do
    test "returns stats map with expected keys", %{view_name: view_name} do
      {:ok, pid} = Root.start_link(name: ".", view_name: view_name)

      stats = Root.stats(pid)

      assert Map.has_key?(stats, :name)
      assert Map.has_key?(stats, :root_server_count)
      assert Map.has_key?(stats, :query_count)
      assert Map.has_key?(stats, :created_at)

      GenServer.stop(pid)
    end

    test "returns correct initial values", %{view_name: view_name} do
      {:ok, pid} = Root.start_link(name: ".", view_name: view_name)

      stats = Root.stats(pid)

      assert stats.name == "."
      assert stats.root_server_count == 13
      assert stats.query_count == 0
      assert %DateTime{} = stats.created_at

      GenServer.stop(pid)
    end

    test "root_server_count reflects configured servers", %{view_name: view_name} do
      custom_servers = [{{8, 8, 8, 8}, 53}, {{1, 1, 1, 1}, 53}]

      {:ok, pid} = Root.start_link(name: ".", view_name: view_name, root_servers: custom_servers)

      stats = Root.stats(pid)
      assert stats.root_server_count == 2

      GenServer.stop(pid)
    end

    test "query_count updates after resolve calls", %{view_name: view_name} do
      {:ok, pid} = Root.start_link(name: ".", view_name: view_name)

      for i <- 1..5 do
        Root.resolve(pid, %{name: "test#{i}.com"})
      end

      stats = Root.stats(pid)
      assert stats.query_count == 5

      GenServer.stop(pid)
    end

    test "created_at is set at initialization time", %{view_name: view_name} do
      before = DateTime.utc_now()
      {:ok, pid} = Root.start_link(name: ".", view_name: view_name)
      after_start = DateTime.utc_now()

      stats = Root.stats(pid)

      # created_at should be between before and after_start
      assert not DateTime.before?(stats.created_at, before)
      assert not DateTime.after?(stats.created_at, after_start)

      GenServer.stop(pid)
    end
  end

  describe "Zone.Behaviour implementation" do
    test "implements all required callbacks" do
      # Ensure module is loaded
      {:module, _} = Code.ensure_loaded(Root)

      # Verify the module exports all required Behaviour functions
      Code.ensure_loaded!(Root)
      assert function_exported?(Root, :get_name, 1)
      Code.ensure_loaded!(Root)
      assert function_exported?(Root, :resolve, 2)
      Code.ensure_loaded!(Root)
      assert function_exported?(Root, :reload, 2)
      Code.ensure_loaded!(Root)
      assert function_exported?(Root, :stats, 1)
    end
  end

  describe "concurrent access" do
    test "handles concurrent resolve calls", %{view_name: view_name} do
      {:ok, pid} = Root.start_link(name: ".", view_name: view_name)

      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            Root.resolve(pid, %{name: "test#{i}.com"})
          end)
        end

      results = Task.await_many(tasks, 5000)

      # All should return referrals
      for result <- results do
        assert {:referral, _servers} = result
      end

      # Query count should be 10
      stats = Root.stats(pid)
      assert stats.query_count == 10

      GenServer.stop(pid)
    end

    test "handles concurrent stats calls", %{view_name: view_name} do
      {:ok, pid} = Root.start_link(name: ".", view_name: view_name)

      tasks =
        for _i <- 1..10 do
          Task.async(fn ->
            Root.stats(pid)
          end)
        end

      results = Task.await_many(tasks, 5000)

      # All should return valid stats
      for stats <- results do
        assert is_map(stats)
        assert Map.has_key?(stats, :query_count)
      end

      GenServer.stop(pid)
    end
  end

  describe "default root server IPs" do
    test "default servers are valid IPv4 tuples", %{view_name: view_name} do
      {:ok, pid} = Root.start_link(name: ".", view_name: view_name)

      servers = Root.get_root_servers(pid)

      for {ip, port} <- servers do
        assert is_tuple(ip)
        assert tuple_size(ip) == 4
        {a, b, c, d} = ip
        assert is_integer(a) and a >= 0 and a <= 255
        assert is_integer(b) and b >= 0 and b <= 255
        assert is_integer(c) and c >= 0 and c <= 255
        assert is_integer(d) and d >= 0 and d <= 255
        assert port == 53
      end

      GenServer.stop(pid)
    end

    test "includes 13 root servers (a-m)", %{view_name: view_name} do
      {:ok, pid} = Root.start_link(name: ".", view_name: view_name)

      servers = Root.get_root_servers(pid)
      assert length(servers) == 13

      GenServer.stop(pid)
    end
  end
end
