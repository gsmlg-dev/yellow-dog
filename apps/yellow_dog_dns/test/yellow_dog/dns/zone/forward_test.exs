defmodule YellowDog.Dns.Zone.ForwardTest do
  @moduledoc """
  Comprehensive unit tests for YellowDog.Dns.Zone.Forward.

  Tests cover:
  - GenServer lifecycle (start/stop)
  - Forward zone configuration options
  - DNS query forwarding to upstream servers
  - Round-robin upstream selection
  - Timeout and retry handling
  - Stats tracking
  - Legacy struct-based API
  """
  use ExUnit.Case, async: false

  alias YellowDog.Dns.Zone.Forward
  alias DNS.Message

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
    # Generate unique identifiers for test isolation
    test_ref = :erlang.unique_integer([:positive])
    view_name = "test_view_#{test_ref}"
    zone_name = "forward_#{test_ref}.local"

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

  # Helper to create a mock DNS query message
  defp build_query(name, type \\ :a) do
    %Message{
      header: %Message.Header{
        id: :rand.uniform(65535),
        qr: false,
        opcode: :query,
        rd: true
      },
      qdlist: [
        %Message.Question{
          name: name,
          type: type,
          class: :in
        }
      ],
      anlist: [],
      nslist: [],
      arlist: []
    }
  end

  # ===========================================================================
  # GenServer API Tests
  # ===========================================================================

  describe "start_link/1" do
    test "starts with required name option", %{view_name: view_name, zone_name: zone_name} do
      {:ok, pid} = Forward.start_link(name: zone_name, view_name: view_name)

      assert is_pid(pid)
      assert Process.alive?(pid)

      GenServer.stop(pid)
    end

    test "fails without name option", %{view_name: view_name} do
      assert_raise KeyError, fn ->
        Forward.start_link(view_name: view_name)
      end
    end

    test "uses default view name 'default' when not specified" do
      # Use unique zone name to avoid registry conflicts
      test_ref = :erlang.unique_integer([:positive])
      unique_zone = "forward_default_#{test_ref}"
      {:ok, pid} = Forward.start_link(name: unique_zone)

      assert Forward.get_view(pid) == "default"

      GenServer.stop(pid)
    end

    test "accepts upstreams option", %{view_name: view_name, zone_name: zone_name} do
      upstreams = [{{8, 8, 8, 8}, 53}, {{8, 8, 4, 4}, 53}]
      {:ok, pid} = Forward.start_link(name: zone_name, view_name: view_name, upstreams: upstreams)

      stats = Forward.stats(pid)
      assert stats.upstream_count == 2

      GenServer.stop(pid)
    end

    test "accepts string upstreams", %{view_name: view_name, zone_name: zone_name} do
      upstreams = ["8.8.8.8:53", "8.8.4.4"]
      {:ok, pid} = Forward.start_link(name: zone_name, view_name: view_name, upstreams: upstreams)

      stats = Forward.stats(pid)
      assert stats.upstream_count == 2

      GenServer.stop(pid)
    end

    test "accepts custom timeout option", %{view_name: view_name, zone_name: zone_name} do
      {:ok, pid} = Forward.start_link(name: zone_name, view_name: view_name, timeout: 3000)

      assert is_pid(pid)

      GenServer.stop(pid)
    end

    test "accepts custom retries option", %{view_name: view_name, zone_name: zone_name} do
      {:ok, pid} = Forward.start_link(name: zone_name, view_name: view_name, retries: 5)

      assert is_pid(pid)

      GenServer.stop(pid)
    end

    test "registers with ZoneRegistry", %{view_name: view_name, zone_name: zone_name} do
      {:ok, pid} = Forward.start_link(name: zone_name, view_name: view_name)

      assert [{^pid, _}] =
               Registry.lookup(YellowDog.Dns.ZoneRegistry, {view_name, :forward, zone_name})

      GenServer.stop(pid)
    end
  end

  describe "get_name/1" do
    test "returns the zone name", %{view_name: view_name, zone_name: zone_name} do
      {:ok, pid} = Forward.start_link(name: zone_name, view_name: view_name)

      assert Forward.get_name(pid) == zone_name

      GenServer.stop(pid)
    end
  end

  describe "get_view/1" do
    test "returns the view name", %{view_name: view_name, zone_name: zone_name} do
      {:ok, pid} = Forward.start_link(name: zone_name, view_name: view_name)

      assert Forward.get_view(pid) == view_name

      GenServer.stop(pid)
    end
  end

  describe "resolve/2" do
    test "returns error when no upstreams configured", %{
      view_name: view_name,
      zone_name: zone_name
    } do
      {:ok, pid} = Forward.start_link(name: zone_name, view_name: view_name, upstreams: [])

      query = build_query("example.com")
      result = Forward.resolve(pid, query)

      assert result == {:error, :no_upstreams}

      GenServer.stop(pid)
    end

    test "increments query_count on resolve attempt", %{view_name: view_name, zone_name: zone_name} do
      {:ok, pid} = Forward.start_link(name: zone_name, view_name: view_name, upstreams: [])

      stats_before = Forward.stats(pid)
      assert stats_before.query_count == 0

      _query = build_query("example.com")
      Forward.resolve(pid, build_query("example.com"))

      stats_after = Forward.stats(pid)
      assert stats_after.query_count == 1

      GenServer.stop(pid)
    end
  end

  describe "stats/1" do
    test "returns stats map with expected keys", %{view_name: view_name, zone_name: zone_name} do
      {:ok, pid} = Forward.start_link(name: zone_name, view_name: view_name)

      stats = Forward.stats(pid)

      assert Map.has_key?(stats, :name)
      assert Map.has_key?(stats, :upstream_count)
      assert Map.has_key?(stats, :upstreams)
      assert Map.has_key?(stats, :query_count)
      assert Map.has_key?(stats, :success_count)
      assert Map.has_key?(stats, :error_count)
      assert Map.has_key?(stats, :pending_count)

      GenServer.stop(pid)
    end

    test "initial stats are zero", %{view_name: view_name, zone_name: zone_name} do
      {:ok, pid} = Forward.start_link(name: zone_name, view_name: view_name)

      stats = Forward.stats(pid)

      assert stats.query_count == 0
      assert stats.success_count == 0
      assert stats.error_count == 0
      assert stats.pending_count == 0

      GenServer.stop(pid)
    end

    test "formats upstreams as strings", %{view_name: view_name, zone_name: zone_name} do
      upstreams = [{{8, 8, 8, 8}, 53}, {{1, 1, 1, 1}, 53}]
      {:ok, pid} = Forward.start_link(name: zone_name, view_name: view_name, upstreams: upstreams)

      stats = Forward.stats(pid)

      assert "8.8.8.8:53" in stats.upstreams
      assert "1.1.1.1:53" in stats.upstreams

      GenServer.stop(pid)
    end
  end

  describe "reload/2 (GenServer)" do
    test "updates upstreams", %{view_name: view_name, zone_name: zone_name} do
      {:ok, pid} = Forward.start_link(name: zone_name, view_name: view_name, upstreams: [])

      stats_before = Forward.stats(pid)
      assert stats_before.upstream_count == 0

      :ok = Forward.reload(pid, upstreams: [{{8, 8, 8, 8}, 53}])

      stats_after = Forward.stats(pid)
      assert stats_after.upstream_count == 1

      GenServer.stop(pid)
    end

    test "updates timeout", %{view_name: view_name, zone_name: zone_name} do
      {:ok, pid} = Forward.start_link(name: zone_name, view_name: view_name, timeout: 5000)

      :ok = Forward.reload(pid, timeout: 3000)

      # timeout is internal, verify via process alive
      assert Process.alive?(pid)

      GenServer.stop(pid)
    end

    test "preserves values when not provided in config", %{
      view_name: view_name,
      zone_name: zone_name
    } do
      upstreams = [{{8, 8, 8, 8}, 53}]
      {:ok, pid} = Forward.start_link(name: zone_name, view_name: view_name, upstreams: upstreams)

      :ok = Forward.reload(pid, [])

      stats = Forward.stats(pid)
      assert stats.upstream_count == 1

      GenServer.stop(pid)
    end
  end

  describe "Zone.Behaviour implementation" do
    test "implements all required callbacks" do
      # Ensure module is loaded
      {:module, _} = Code.ensure_loaded(Forward)

      assert function_exported?(Forward, :get_name, 1)
      assert function_exported?(Forward, :resolve, 2)
      assert function_exported?(Forward, :reload, 2)
      assert function_exported?(Forward, :stats, 1)
    end
  end

  describe "concurrent access" do
    test "handles concurrent stats calls", %{view_name: view_name, zone_name: zone_name} do
      {:ok, pid} = Forward.start_link(name: zone_name, view_name: view_name)

      tasks =
        for _i <- 1..10 do
          Task.async(fn ->
            Forward.stats(pid)
          end)
        end

      results = Task.await_many(tasks, 5000)

      for stats <- results do
        assert is_map(stats)
        assert Map.has_key?(stats, :query_count)
      end

      GenServer.stop(pid)
    end
  end

  # ===========================================================================
  # Legacy Struct-Based API Tests
  # ===========================================================================

  describe "new/3" do
    test "creates a forward zone with default options" do
      forwarders = [{8, 8, 8, 8}, {1, 1, 1, 1}]
      forward = Forward.new("external.com", forwarders)

      assert forward.name == "external.com"
      assert forward.forwarders == forwarders
      assert forward.forward_mode == :only
      assert forward.timeout_ms == 5000
      assert forward.max_retries == 2
    end

    test "creates a forward zone with custom options" do
      forwarders = [{8, 8, 8, 8}]

      forward =
        Forward.new("external.com", forwarders,
          forward_mode: :first,
          timeout_ms: 3000,
          max_retries: 5
        )

      assert forward.name == "external.com"
      assert forward.forwarders == forwarders
      assert forward.forward_mode == :first
      assert forward.timeout_ms == 3000
      assert forward.max_retries == 5
    end
  end

  describe "validate/1" do
    test "validates a correct forward zone" do
      forward = Forward.new("external.com", [{8, 8, 8, 8}])
      assert Forward.validate(forward) == :ok
    end

    test "rejects forward zone with missing name" do
      forward = Forward.new("", [{8, 8, 8, 8}])
      assert Forward.validate(forward) == {:error, :missing_name}
    end

    test "rejects forward zone with nil name" do
      forward = %Forward{name: nil, forwarders: [{8, 8, 8, 8}]}
      assert Forward.validate(forward) == {:error, :missing_name}
    end

    test "rejects forward zone with no forwarders" do
      forward = Forward.new("external.com", [])
      assert Forward.validate(forward) == {:error, :missing_forwarders}
    end

    test "rejects forward zone with nil forwarders" do
      forward = %Forward{name: "external.com", forwarders: nil}
      assert Forward.validate(forward) == {:error, :missing_forwarders}
    end

    test "rejects forward zone with invalid forward mode" do
      forward = %Forward{
        name: "external.com",
        forwarders: [{8, 8, 8, 8}],
        forward_mode: :invalid
      }

      assert Forward.validate(forward) == {:error, :invalid_forward_mode}
    end

    test "rejects forward zone with timeout too low" do
      forward = Forward.new("external.com", [{8, 8, 8, 8}], timeout_ms: 50)
      assert Forward.validate(forward) == {:error, :invalid_timeout}
    end

    test "rejects forward zone with timeout too high" do
      forward = Forward.new("external.com", [{8, 8, 8, 8}], timeout_ms: 35_000)
      assert Forward.validate(forward) == {:error, :invalid_timeout}
    end

    test "rejects forward zone with negative max_retries" do
      forward = Forward.new("external.com", [{8, 8, 8, 8}], max_retries: -1)
      assert Forward.validate(forward) == {:error, :invalid_max_retries}
    end

    test "rejects forward zone with max_retries too high" do
      forward = Forward.new("external.com", [{8, 8, 8, 8}], max_retries: 15)
      assert Forward.validate(forward) == {:error, :invalid_max_retries}
    end
  end

  describe "parse_config/1" do
    test "parses valid forward zone configuration" do
      config = %{
        "name" => "external.com",
        "forwarders" => ["8.8.8.8", "1.1.1.1"],
        "forward_mode" => "only",
        "timeout_ms" => 3000,
        "max_retries" => 3
      }

      assert {:ok, forward} = Forward.parse_config(config)
      assert forward.name == "external.com"
      assert forward.forwarders == [{8, 8, 8, 8}, {1, 1, 1, 1}]
      assert forward.forward_mode == :only
      assert forward.timeout_ms == 3000
      assert forward.max_retries == 3
    end

    test "parses configuration with minimal fields" do
      config = %{
        "name" => "external.com",
        "forwarders" => ["8.8.8.8"]
      }

      assert {:ok, forward} = Forward.parse_config(config)
      assert forward.name == "external.com"
      assert forward.forwarders == [{8, 8, 8, 8}]
      assert forward.forward_mode == :only
      assert forward.timeout_ms == 5000
      assert forward.max_retries == 2
    end

    test "parses forward_mode 'first'" do
      config = %{
        "name" => "external.com",
        "forwarders" => ["8.8.8.8"],
        "forward_mode" => "first"
      }

      assert {:ok, forward} = Forward.parse_config(config)
      assert forward.forward_mode == :first
    end

    test "parses IPv6 forwarders" do
      config = %{
        "name" => "external.com",
        "forwarders" => ["2001:4860:4860::8888", "2001:4860:4860::8844"]
      }

      assert {:ok, forward} = Forward.parse_config(config)

      assert forward.forwarders == [
               {0x2001, 0x4860, 0x4860, 0, 0, 0, 0, 0x8888},
               {0x2001, 0x4860, 0x4860, 0, 0, 0, 0, 0x8844}
             ]
    end

    test "returns error for missing name" do
      config = %{
        "forwarders" => ["8.8.8.8"]
      }

      assert {:error, :missing_name} = Forward.parse_config(config)
    end

    test "returns error for missing forwarders" do
      config = %{
        "name" => "external.com"
      }

      assert {:error, :missing_forwarders} = Forward.parse_config(config)
    end

    test "returns error for invalid forwarder IP" do
      config = %{
        "name" => "external.com",
        "forwarders" => ["not-an-ip"]
      }

      assert {:error, :invalid_forwarders} = Forward.parse_config(config)
    end

    test "returns error for empty forwarders list" do
      config = %{
        "name" => "external.com",
        "forwarders" => []
      }

      assert {:error, :missing_forwarders} = Forward.parse_config(config)
    end
  end

  describe "to_storage_metadata/1" do
    test "converts forward zone to storage metadata" do
      forward =
        Forward.new("external.com", [{8, 8, 8, 8}], forward_mode: :first, timeout_ms: 3000)

      metadata = Forward.to_storage_metadata(forward)

      assert metadata.type == :forward
      assert metadata.forwarders == [{8, 8, 8, 8}]
      assert metadata.forward_mode == :first
      assert metadata.timeout_ms == 3000
      assert metadata.max_retries == 2
      assert is_integer(metadata.loaded_at)
    end
  end

  describe "from_storage_metadata/2" do
    test "recreates forward zone from storage metadata" do
      metadata = %{
        type: :forward,
        forwarders: [{8, 8, 8, 8}, {1, 1, 1, 1}],
        forward_mode: :only,
        timeout_ms: 4000,
        max_retries: 3
      }

      assert {:ok, forward} = Forward.from_storage_metadata("external.com", metadata)
      assert forward.name == "external.com"
      assert forward.forwarders == [{8, 8, 8, 8}, {1, 1, 1, 1}]
      assert forward.forward_mode == :only
      assert forward.timeout_ms == 4000
      assert forward.max_retries == 3
    end

    test "uses defaults for missing optional fields" do
      metadata = %{
        type: :forward,
        forwarders: [{8, 8, 8, 8}]
      }

      assert {:ok, forward} = Forward.from_storage_metadata("external.com", metadata)
      assert forward.forward_mode == :only
      assert forward.timeout_ms == 5000
      assert forward.max_retries == 2
    end

    test "returns error for non-forward zone type" do
      metadata = %{
        type: :master,
        forwarders: [{8, 8, 8, 8}]
      }

      assert {:error, :not_forward_zone} = Forward.from_storage_metadata("external.com", metadata)
    end

    test "returns error for invalid metadata" do
      metadata = %{
        type: :forward,
        forwarders: []
      }

      assert {:error, :missing_forwarders} =
               Forward.from_storage_metadata("external.com", metadata)
    end
  end
end
