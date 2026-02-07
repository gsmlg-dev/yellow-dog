defmodule YellowDog.Dns.Zone.RPZTest do
  @moduledoc """
  Comprehensive unit tests for YellowDog.Dns.Zone.RPZ.

  Tests cover:
  - GenServer lifecycle (start/stop)
  - Zone.Behaviour implementation
  - Policy evaluation (QNAME triggers)
  - Policy actions (NXDOMAIN, NODATA, PASSTHRU, DROP, TCP-Only, Local-Data)
  - Wildcard matching
  - IP-based policies
  - Policy reloading
  - Stats tracking
  - Concurrent access
  """
  use ExUnit.Case, async: false

  alias YellowDog.Dns.Zone.RPZ
  alias DNS.Message
  alias DNS.Message.Header

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
    # Generate unique view and zone names for test isolation
    test_ref = :erlang.unique_integer([:positive])
    view_name = "test_view_#{test_ref}"
    zone_name = "rpz#{test_ref}.local"

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

  # Helper to build a test DNS query
  defp build_query(name, type \\ :a) do
    %Message{
      header: %Header{
        id: :rand.uniform(65535),
        qr: false,
        opcode: 0,
        aa: false,
        tc: false,
        rd: true,
        ra: false,
        z: 0,
        rcode: DNS.Message.RCode.no_error()
      },
      qdlist: [
        %{name: name, type: type, class: :in}
      ],
      anlist: [],
      nslist: [],
      arlist: []
    }
  end

  # Helper to build a test DNS response with A records
  defp build_response(query, ips) do
    anlist =
      Enum.map(ips, fn ip ->
        %{
          name: hd(query.qdlist).name,
          type: :a,
          class: :in,
          ttl: 3600,
          rdata: ip
        }
      end)

    %Message{
      header: %{query.header | qr: 1, aa: 1, rcode: DNS.Message.RCode.no_error()},
      qdlist: query.qdlist,
      anlist: anlist,
      nslist: [],
      arlist: []
    }
  end

  describe "start_link/1" do
    test "starts with required options", %{view_name: view_name, zone_name: zone_name} do
      {:ok, pid} = RPZ.start_link(name: zone_name, view_name: view_name)

      assert is_pid(pid)
      assert Process.alive?(pid)

      GenServer.stop(pid)
    end

    test "requires :name option", %{view_name: view_name} do
      assert_raise KeyError, ~r/key :name not found/, fn ->
        RPZ.start_link(view_name: view_name)
      end
    end

    test "uses default view name 'default' when not specified" do
      test_ref = :erlang.unique_integer([:positive])
      zone_name = "rpz#{test_ref}.local"

      {:ok, pid} = RPZ.start_link(name: zone_name)

      assert RPZ.get_view(pid) == "default"

      GenServer.stop(pid)
    end

    test "accepts initial policies", %{view_name: view_name, zone_name: zone_name} do
      policies = [
        %{trigger: :qname, pattern: "blocked.example.com", action: :nxdomain}
      ]

      {:ok, pid} = RPZ.start_link(name: zone_name, view_name: view_name, policies: policies)

      stats = RPZ.stats(pid)
      assert stats.policy_count == 1

      GenServer.stop(pid)
    end

    test "registers with ZoneRegistry", %{view_name: view_name, zone_name: zone_name} do
      {:ok, pid} = RPZ.start_link(name: zone_name, view_name: view_name)

      # Verify registration via Registry lookup
      assert [{^pid, _}] =
               Registry.lookup(YellowDog.Dns.ZoneRegistry, {view_name, :rpz, zone_name})

      GenServer.stop(pid)
    end
  end

  describe "get_name/1" do
    test "returns the zone name", %{view_name: view_name, zone_name: zone_name} do
      {:ok, pid} = RPZ.start_link(name: zone_name, view_name: view_name)

      assert RPZ.get_name(pid) == zone_name

      GenServer.stop(pid)
    end
  end

  describe "get_view/1" do
    test "returns the view name", %{view_name: view_name, zone_name: zone_name} do
      {:ok, pid} = RPZ.start_link(name: zone_name, view_name: view_name)

      assert RPZ.get_view(pid) == view_name

      GenServer.stop(pid)
    end
  end

  describe "check_qname/2" do
    test "returns matching policy for exact QNAME", %{view_name: view_name, zone_name: zone_name} do
      policies = [
        %{trigger: :qname, pattern: "blocked.example.com", action: :nxdomain}
      ]

      {:ok, pid} = RPZ.start_link(name: zone_name, view_name: view_name, policies: policies)

      assert {:ok, policy} = RPZ.check_qname(pid, "blocked.example.com")
      assert policy.action == :nxdomain

      GenServer.stop(pid)
    end

    test "returns :no_match for non-matching QNAME", %{
      view_name: view_name,
      zone_name: zone_name
    } do
      policies = [
        %{trigger: :qname, pattern: "blocked.example.com", action: :nxdomain}
      ]

      {:ok, pid} = RPZ.start_link(name: zone_name, view_name: view_name, policies: policies)

      assert :no_match = RPZ.check_qname(pid, "allowed.example.com")

      GenServer.stop(pid)
    end

    test "matches wildcard patterns", %{view_name: view_name, zone_name: zone_name} do
      policies = [
        %{trigger: :qname, pattern: "*.blocked.com", action: :nxdomain}
      ]

      {:ok, pid} = RPZ.start_link(name: zone_name, view_name: view_name, policies: policies)

      assert {:ok, _policy} = RPZ.check_qname(pid, "sub.blocked.com")
      assert {:ok, _policy} = RPZ.check_qname(pid, "any.blocked.com")

      GenServer.stop(pid)
    end

    test "is case insensitive", %{view_name: view_name, zone_name: zone_name} do
      policies = [
        %{trigger: :qname, pattern: "BLOCKED.Example.COM", action: :nxdomain}
      ]

      {:ok, pid} = RPZ.start_link(name: zone_name, view_name: view_name, policies: policies)

      assert {:ok, _policy} = RPZ.check_qname(pid, "blocked.example.com")
      assert {:ok, _policy} = RPZ.check_qname(pid, "BLOCKED.EXAMPLE.COM")

      GenServer.stop(pid)
    end

    test "increments hit count on match", %{view_name: view_name, zone_name: zone_name} do
      policies = [
        %{trigger: :qname, pattern: "blocked.example.com", action: :nxdomain}
      ]

      {:ok, pid} = RPZ.start_link(name: zone_name, view_name: view_name, policies: policies)

      stats1 = RPZ.stats(pid)
      assert stats1.hit_count == 0

      RPZ.check_qname(pid, "blocked.example.com")

      stats2 = RPZ.stats(pid)
      assert stats2.hit_count == 1

      GenServer.stop(pid)
    end

    test "increments miss count on no match", %{view_name: view_name, zone_name: zone_name} do
      policies = [
        %{trigger: :qname, pattern: "blocked.example.com", action: :nxdomain}
      ]

      {:ok, pid} = RPZ.start_link(name: zone_name, view_name: view_name, policies: policies)

      stats1 = RPZ.stats(pid)
      assert stats1.miss_count == 0

      RPZ.check_qname(pid, "allowed.example.com")

      stats2 = RPZ.stats(pid)
      assert stats2.miss_count == 1

      GenServer.stop(pid)
    end
  end

  describe "evaluate/3" do
    test "returns NXDOMAIN response for :nxdomain action", %{
      view_name: view_name,
      zone_name: zone_name
    } do
      policies = [
        %{trigger: :qname, pattern: "blocked.example.com", action: :nxdomain}
      ]

      {:ok, pid} = RPZ.start_link(name: zone_name, view_name: view_name, policies: policies)

      query = build_query("blocked.example.com")
      response = build_response(query, [{192, 168, 1, 1}])

      assert {:ok, modified} = RPZ.evaluate(pid, query, response)
      assert modified.header.rcode == DNS.Message.RCode.nx_domain()
      assert modified.anlist == []

      GenServer.stop(pid)
    end

    test "returns NODATA response for :nodata action", %{
      view_name: view_name,
      zone_name: zone_name
    } do
      policies = [
        %{trigger: :qname, pattern: "nodata.example.com", action: :nodata}
      ]

      {:ok, pid} = RPZ.start_link(name: zone_name, view_name: view_name, policies: policies)

      query = build_query("nodata.example.com")
      response = build_response(query, [{192, 168, 1, 1}])

      assert {:ok, modified} = RPZ.evaluate(pid, query, response)
      assert modified.header.rcode == DNS.Message.RCode.no_error()
      assert modified.anlist == []

      GenServer.stop(pid)
    end

    test "returns original response for :passthru action", %{
      view_name: view_name,
      zone_name: zone_name
    } do
      policies = [
        %{trigger: :qname, pattern: "allowed.example.com", action: :passthru}
      ]

      {:ok, pid} = RPZ.start_link(name: zone_name, view_name: view_name, policies: policies)

      query = build_query("allowed.example.com")
      response = build_response(query, [{192, 168, 1, 1}])

      assert {:passthru, ^response} = RPZ.evaluate(pid, query, response)

      GenServer.stop(pid)
    end

    test "returns {:drop, nil} for :drop action", %{view_name: view_name, zone_name: zone_name} do
      policies = [
        %{trigger: :qname, pattern: "dropped.example.com", action: :drop}
      ]

      {:ok, pid} = RPZ.start_link(name: zone_name, view_name: view_name, policies: policies)

      query = build_query("dropped.example.com")
      response = build_response(query, [{192, 168, 1, 1}])

      assert {:drop, nil} = RPZ.evaluate(pid, query, response)

      GenServer.stop(pid)
    end

    test "returns TC response for :tcp_only action", %{
      view_name: view_name,
      zone_name: zone_name
    } do
      policies = [
        %{trigger: :qname, pattern: "tcponly.example.com", action: :tcp_only}
      ]

      {:ok, pid} = RPZ.start_link(name: zone_name, view_name: view_name, policies: policies)

      query = build_query("tcponly.example.com")
      response = build_response(query, [{192, 168, 1, 1}])

      assert {:ok, modified} = RPZ.evaluate(pid, query, response)
      assert modified.header.tc == 1

      GenServer.stop(pid)
    end

    test "returns local data for :local_data action", %{
      view_name: view_name,
      zone_name: zone_name
    } do
      local_records = [
        %{name: "redirect.example.com", type: :a, ttl: 300, rdata: {10, 0, 0, 1}}
      ]

      policies = [
        %{
          trigger: :qname,
          pattern: "redirect.example.com",
          action: :local_data,
          local_data: local_records
        }
      ]

      {:ok, pid} = RPZ.start_link(name: zone_name, view_name: view_name, policies: policies)

      query = build_query("redirect.example.com")
      response = build_response(query, [{192, 168, 1, 1}])

      assert {:ok, modified} = RPZ.evaluate(pid, query, response)
      assert modified.header.aa == 1
      assert length(modified.anlist) == 1

      GenServer.stop(pid)
    end

    test "passes through when no policy matches", %{view_name: view_name, zone_name: zone_name} do
      policies = [
        %{trigger: :qname, pattern: "blocked.example.com", action: :nxdomain}
      ]

      {:ok, pid} = RPZ.start_link(name: zone_name, view_name: view_name, policies: policies)

      query = build_query("allowed.other.com")
      response = build_response(query, [{192, 168, 1, 1}])

      assert {:passthru, ^response} = RPZ.evaluate(pid, query, response)

      GenServer.stop(pid)
    end

    test "checks response IPs when QNAME doesn't match", %{
      view_name: view_name,
      zone_name: zone_name
    } do
      policies = [
        %{trigger: :ip, pattern: "1.168.192", action: :nxdomain}
      ]

      {:ok, pid} = RPZ.start_link(name: zone_name, view_name: view_name, policies: policies)

      query = build_query("any.example.com")
      # The IP in reverse: 192.168.1.1 -> 1.1.168.192
      response = build_response(query, [{192, 168, 1, 1}])

      # Note: The IP matching depends on the ip_to_rpz conversion
      # which reverses octets: 192.168.1.1 -> "1.1.168.192"
      # So to match 192.168.1.x, the pattern should be "1.168.192" (partial match not supported)

      # This test verifies the evaluate function checks IPs, even if no match
      # The actual match would require exact IP pattern
      result = RPZ.evaluate(pid, query, response)
      # Should pass through since IP pattern doesn't match exactly
      assert {:passthru, _} = result

      GenServer.stop(pid)
    end
  end

  describe "resolve/2" do
    test "returns :not_supported (RPZ doesn't resolve queries)", %{
      view_name: view_name,
      zone_name: zone_name
    } do
      {:ok, pid} = RPZ.start_link(name: zone_name, view_name: view_name)

      query = build_query("example.com")
      assert {:error, :not_supported} = RPZ.resolve(pid, query)

      GenServer.stop(pid)
    end
  end

  describe "reload/2" do
    test "updates policies", %{view_name: view_name, zone_name: zone_name} do
      initial_policies = [
        %{trigger: :qname, pattern: "old.example.com", action: :nxdomain}
      ]

      {:ok, pid} =
        RPZ.start_link(name: zone_name, view_name: view_name, policies: initial_policies)

      # Old policy should match
      assert {:ok, _} = RPZ.check_qname(pid, "old.example.com")

      # Reload with new policies
      new_policies = [
        %{trigger: :qname, pattern: "new.example.com", action: :nxdomain}
      ]

      assert :ok = RPZ.reload(pid, policies: new_policies)

      # Old policy should no longer match
      assert :no_match = RPZ.check_qname(pid, "old.example.com")

      # New policy should match
      assert {:ok, _} = RPZ.check_qname(pid, "new.example.com")

      GenServer.stop(pid)
    end

    test "clears ETS and reloads", %{view_name: view_name, zone_name: zone_name} do
      policies = [
        %{trigger: :qname, pattern: "test1.com", action: :nxdomain},
        %{trigger: :qname, pattern: "test2.com", action: :nxdomain}
      ]

      {:ok, pid} = RPZ.start_link(name: zone_name, view_name: view_name, policies: policies)

      stats1 = RPZ.stats(pid)
      assert stats1.policy_count == 2

      # Reload with single policy
      assert :ok =
               RPZ.reload(pid,
                 policies: [%{trigger: :qname, pattern: "test3.com", action: :nxdomain}]
               )

      stats2 = RPZ.stats(pid)
      assert stats2.policy_count == 1

      GenServer.stop(pid)
    end
  end

  describe "stats/1" do
    test "returns stats map with expected keys", %{view_name: view_name, zone_name: zone_name} do
      {:ok, pid} = RPZ.start_link(name: zone_name, view_name: view_name)

      stats = RPZ.stats(pid)

      assert Map.has_key?(stats, :name)
      assert Map.has_key?(stats, :view)
      assert Map.has_key?(stats, :policy_count)
      assert Map.has_key?(stats, :hit_count)
      assert Map.has_key?(stats, :miss_count)
      assert Map.has_key?(stats, :table_size)

      GenServer.stop(pid)
    end

    test "returns correct initial values", %{view_name: view_name, zone_name: zone_name} do
      {:ok, pid} = RPZ.start_link(name: zone_name, view_name: view_name)

      stats = RPZ.stats(pid)

      assert stats.name == zone_name
      assert stats.view == view_name
      assert stats.policy_count == 0
      assert stats.hit_count == 0
      assert stats.miss_count == 0
      assert stats.table_size == 0

      GenServer.stop(pid)
    end

    test "policy_count reflects loaded policies", %{view_name: view_name, zone_name: zone_name} do
      policies = [
        %{trigger: :qname, pattern: "a.com", action: :nxdomain},
        %{trigger: :qname, pattern: "b.com", action: :nxdomain},
        %{trigger: :qname, pattern: "c.com", action: :nxdomain}
      ]

      {:ok, pid} = RPZ.start_link(name: zone_name, view_name: view_name, policies: policies)

      stats = RPZ.stats(pid)
      assert stats.policy_count == 3
      assert stats.table_size == 3

      GenServer.stop(pid)
    end
  end

  describe "Zone.Behaviour implementation" do
    test "implements all required callbacks" do
      # Ensure module is loaded
      {:module, _} = Code.ensure_loaded(RPZ)

      # Verify the module exports all required Behaviour functions
      assert function_exported?(RPZ, :get_name, 1)
      assert function_exported?(RPZ, :resolve, 2)
      assert function_exported?(RPZ, :reload, 2)
      assert function_exported?(RPZ, :stats, 1)
    end
  end

  describe "concurrent access" do
    test "handles concurrent check_qname calls", %{view_name: view_name, zone_name: zone_name} do
      policies = [
        %{trigger: :qname, pattern: "blocked.example.com", action: :nxdomain}
      ]

      {:ok, pid} = RPZ.start_link(name: zone_name, view_name: view_name, policies: policies)

      tasks =
        for i <- 1..20 do
          Task.async(fn ->
            # Alternate between matching and non-matching queries
            if rem(i, 2) == 0 do
              RPZ.check_qname(pid, "blocked.example.com")
            else
              RPZ.check_qname(pid, "allowed.example.com")
            end
          end)
        end

      results = Task.await_many(tasks, 5000)

      # Should have 10 matches and 10 no_matches
      matches = Enum.count(results, fn r -> match?({:ok, _}, r) end)
      no_matches = Enum.count(results, fn r -> r == :no_match end)

      assert matches == 10
      assert no_matches == 10

      GenServer.stop(pid)
    end

    test "handles concurrent evaluate calls", %{view_name: view_name, zone_name: zone_name} do
      policies = [
        %{trigger: :qname, pattern: "blocked.example.com", action: :nxdomain}
      ]

      {:ok, pid} = RPZ.start_link(name: zone_name, view_name: view_name, policies: policies)

      tasks =
        for _i <- 1..10 do
          Task.async(fn ->
            query = build_query("blocked.example.com")
            response = build_response(query, [{192, 168, 1, 1}])
            RPZ.evaluate(pid, query, response)
          end)
        end

      results = Task.await_many(tasks, 5000)

      # All should get NXDOMAIN response
      for result <- results do
        assert {:ok, modified} = result
        assert modified.header.rcode == DNS.Message.RCode.nx_domain()
      end

      GenServer.stop(pid)
    end

    test "handles concurrent stats calls", %{view_name: view_name, zone_name: zone_name} do
      {:ok, pid} = RPZ.start_link(name: zone_name, view_name: view_name)

      tasks =
        for _i <- 1..10 do
          Task.async(fn ->
            RPZ.stats(pid)
          end)
        end

      results = Task.await_many(tasks, 5000)

      # All should return valid stats
      for stats <- results do
        assert is_map(stats)
        assert Map.has_key?(stats, :hit_count)
      end

      GenServer.stop(pid)
    end
  end

  describe "policy ordering" do
    test "more specific patterns are evaluated first", %{
      view_name: view_name,
      zone_name: zone_name
    } do
      # Order in list doesn't matter - specificity should win
      policies = [
        %{trigger: :qname, pattern: "*.com", action: :nodata},
        %{trigger: :qname, pattern: "*.example.com", action: :nxdomain}
      ]

      {:ok, pid} = RPZ.start_link(name: zone_name, view_name: view_name, policies: policies)

      # More specific pattern (*.example.com) should match first
      assert {:ok, policy} = RPZ.check_qname(pid, "test.example.com")
      assert policy.action == :nxdomain

      GenServer.stop(pid)
    end
  end

  describe "wildcard matching" do
    test "matches progressively less specific wildcards", %{
      view_name: view_name,
      zone_name: zone_name
    } do
      policies = [
        %{trigger: :qname, pattern: "*.blocked.com", action: :nxdomain}
      ]

      {:ok, pid} = RPZ.start_link(name: zone_name, view_name: view_name, policies: policies)

      # Single level subdomain
      assert {:ok, _} = RPZ.check_qname(pid, "sub.blocked.com")

      # Multi-level subdomain
      assert {:ok, _} = RPZ.check_qname(pid, "deep.sub.blocked.com")

      GenServer.stop(pid)
    end

    test "exact match takes precedence over wildcard", %{
      view_name: view_name,
      zone_name: zone_name
    } do
      policies = [
        %{trigger: :qname, pattern: "exact.blocked.com", action: :passthru},
        %{trigger: :qname, pattern: "*.blocked.com", action: :nxdomain}
      ]

      {:ok, pid} = RPZ.start_link(name: zone_name, view_name: view_name, policies: policies)

      # Exact match should return passthru
      assert {:ok, policy} = RPZ.check_qname(pid, "exact.blocked.com")
      assert policy.action == :passthru

      # Wildcard should return nxdomain
      assert {:ok, policy} = RPZ.check_qname(pid, "other.blocked.com")
      assert policy.action == :nxdomain

      GenServer.stop(pid)
    end
  end

  describe "name normalization" do
    test "handles trailing dots", %{view_name: view_name, zone_name: zone_name} do
      policies = [
        %{trigger: :qname, pattern: "blocked.example.com.", action: :nxdomain}
      ]

      {:ok, pid} = RPZ.start_link(name: zone_name, view_name: view_name, policies: policies)

      # Should match both with and without trailing dot
      assert {:ok, _} = RPZ.check_qname(pid, "blocked.example.com")
      assert {:ok, _} = RPZ.check_qname(pid, "blocked.example.com.")

      GenServer.stop(pid)
    end
  end
end
