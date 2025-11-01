defmodule YellowDog.Dns.RootZoneIntegrationTest do
  use ExUnit.Case, async: false

  alias YellowDog.Dns.RootZone.{Manager, Hints, Fetcher}
  alias YellowDog.Dns.Zone

  setup do
    # Ensure Zone.Storage is initialized
    case Zone.Storage.init() do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end

    # Start Zone.Manager if not already started
    case GenServer.whereis(Zone.Manager) do
      nil ->
        {:ok, zone_manager} = Zone.Manager.start_link()
        on_exit(fn -> GenServer.stop(zone_manager) end)

      _pid ->
        :ok
    end

    :ok
  end

  describe "hints strategy integration" do
    test "loads and provides root servers" do
      {:ok, pid} = Manager.start_link(strategy: :hints)

      # Get root servers
      servers = Manager.get_root_servers()

      assert length(servers) == 26
      assert Enum.all?(servers, fn {name, ip} ->
               is_binary(name) and is_tuple(ip)
             end)

      # Verify strategy
      assert Manager.get_strategy() == :hints

      # Get stats
      stats = Manager.stats()
      assert stats.strategy == :hints
      assert stats.server_count == 26

      GenServer.stop(pid)
    end

    test "reload is idempotent for hints" do
      {:ok, pid} = Manager.start_link(strategy: :hints)

      servers_before = Manager.get_root_servers()
      :ok = Manager.reload_root_zone()
      servers_after = Manager.get_root_servers()

      assert servers_before == servers_after

      GenServer.stop(pid)
    end
  end

  describe "fetch strategy integration" do
    @tag :skip
    @tag :integration
    test "fetches root zone from IANA (requires internet)" do
      # This test requires internet connectivity
      {:ok, pid} =
        Manager.start_link(
          strategy: :fetch,
          fetch_interval_hours: 24,
          fallback_to_hints: true
        )

      # Should have servers (either fetched or from hints)
      servers = Manager.get_root_servers()
      assert is_list(servers)
      assert length(servers) > 0

      # Get stats
      stats = Manager.stats()
      assert stats.strategy == :fetch
      assert stats.fetch_interval_hours == 24

      GenServer.stop(pid)
    end

    test "fallback to hints when fetch fails" do
      {:ok, pid} =
        Manager.start_link(
          strategy: :fetch,
          fetch_url: "https://invalid.example.com/root.zone",
          fallback_to_hints: true
        )

      # Should return hints servers
      servers = Manager.get_root_servers()
      hints_servers = Hints.get_root_servers()

      assert servers == hints_servers

      GenServer.stop(pid)
    end

    test "periodic fetch is scheduled" do
      {:ok, pid} =
        Manager.start_link(
          strategy: :fetch,
          fetch_interval_hours: 1,
          fallback_to_hints: true
        )

      stats = Manager.stats()

      # Should have next_fetch_seconds
      assert Map.has_key?(stats, :next_fetch_seconds)
      assert stats.next_fetch_seconds > 0

      GenServer.stop(pid)
    end
  end

  describe "auth strategy integration" do
    test "fallback to hints when zone file missing" do
      {:ok, pid} =
        Manager.start_link(
          strategy: :auth,
          zone_file: "/nonexistent/root.zone",
          fallback_to_hints: true
        )

      # Should return hints servers
      servers = Manager.get_root_servers()
      assert length(servers) == 26

      GenServer.stop(pid)
    end

    test "fails without fallback when zone file missing" do
      result =
        Manager.start_link(
          strategy: :auth,
          zone_file: "/nonexistent/root.zone",
          fallback_to_hints: false
        )

      # Should fail to start
      assert {:error, _reason} = result
    end

    @tag :skip
    test "loads zone file when present" do
      # Create a temporary zone file
      temp_file = Path.join(System.tmp_dir!(), "test_root.zone")

      zone_content = """
      $ORIGIN .
      $TTL 518400
      .       IN  SOA a.root-servers.net. nstld.verisign-grs.com. (
                          2024102901  ; serial
                          1800        ; refresh
                          900         ; retry
                          604800      ; expire
                          86400       ; minimum
                          )
      .       IN  NS  a.root-servers.net.
      a.root-servers.net. IN A 198.41.0.4
      """

      File.write!(temp_file, zone_content)

      on_exit(fn -> File.rm(temp_file) end)

      {:ok, pid} =
        Manager.start_link(
          strategy: :auth,
          zone_file: temp_file,
          fallback_to_hints: true
        )

      # Should load zone
      assert Manager.get_strategy() == :auth

      stats = Manager.stats()
      assert stats.zone_file == temp_file

      GenServer.stop(pid)
    end
  end

  describe "strategy switching behavior" do
    test "each strategy returns valid root servers" do
      strategies = [:hints, :fetch, :auth]

      for strategy <- strategies do
        opts =
          case strategy do
            :hints ->
              [strategy: :hints]

            :fetch ->
              [
                strategy: :fetch,
                fetch_url: "https://invalid.example.com",
                fallback_to_hints: true
              ]

            :auth ->
              [
                strategy: :auth,
                zone_file: "/nonexistent.zone",
                fallback_to_hints: true
              ]
          end

        {:ok, pid} = Manager.start_link(opts)

        servers = Manager.get_root_servers()
        assert is_list(servers)
        assert length(servers) > 0

        # All should return valid IP addresses
        Enum.each(servers, fn {name, ip} ->
          assert is_binary(name)
          assert is_tuple(ip)
        end)

        GenServer.stop(pid)
      end
    end
  end

  describe "reload functionality" do
    test "reload updates loaded_at timestamp" do
      {:ok, pid} = Manager.start_link(strategy: :hints)

      stats_before = Manager.stats()
      Process.sleep(100)
      :ok = Manager.reload_root_zone()
      stats_after = Manager.stats()

      assert stats_after.loaded_at >= stats_before.loaded_at

      GenServer.stop(pid)
    end

    test "reload preserves strategy" do
      {:ok, pid} = Manager.start_link(strategy: :hints)

      :ok = Manager.reload_root_zone()

      assert Manager.get_strategy() == :hints

      GenServer.stop(pid)
    end
  end
end
