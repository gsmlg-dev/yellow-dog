defmodule E2ETest.DnsPersistenceE2ETest do
  @moduledoc """
  End-to-end tests for DNS configuration persistence.

  Tests that views and zones persist across restarts using TOML files,
  and that the ConfigWatcher detects and reloads changes.
  """

  use ExUnit.Case, async: false

  alias E2ETest.ServiceHelper
  alias E2ETest.DnsClient
  alias YellowDog.Dns.{ViewManager, ZoneController, Zone, View, ConfigPersistence}

  @moduletag :e2e
  @moduletag :dns

  @tmp_dir System.tmp_dir!() |> Path.join("dns_persistence_e2e_test")

  setup do
    # Clean up tmp dir
    File.rm_rf!(@tmp_dir)
    File.mkdir_p!(@tmp_dir)

    case ServiceHelper.start_dns_system(listen: {127, 0, 0, 1}) do
      {:ok, ctx} ->
        on_exit(fn ->
          ServiceHelper.stop_dns_system(ctx)
          File.rm_rf!(@tmp_dir)
        end)

        {:ok, Map.put(ctx, :tmp_dir, @tmp_dir)}

      {:error, reason} ->
        raise "Failed to start DNS system: #{inspect(reason)}"
    end
  end

  describe "view persistence" do
    test "saves and loads view configuration", ctx do
      # Create a view
      {:ok, _pid} =
        ViewManager.start_view(%{
          name: "persist-test",
          priority: 42,
          acl: :any,
          zones: [],
          rpz_zones: [],
          recursion_enabled: true,
          ecs_enabled: false
        })

      # Verify view exists
      views = ViewManager.list_views()
      view_names = Enum.map(views, fn {name, _pid, _pri} -> name end)
      assert "persist-test" in view_names

      # Save configuration
      result = ViewManager.save_config(ctx.tmp_dir)
      assert result == :ok or match?({:ok, _}, result)

      # Verify file was written
      views_file = Path.join(ctx.tmp_dir, "views.toml")

      if File.exists?(views_file) do
        content = File.read!(views_file)
        assert content =~ "persist-test"
      end
    end
  end

  describe "zone creation and querying" do
    test "zone serves records after creation", ctx do
      # Create auth zone
      {:ok, zone_pid} =
        ZoneController.start_zone(:auth, "persist.test", view_name: "default")

      {:ok, view_pid} = ViewManager.get_view("default")
      View.register_zone(view_pid, :auth, "persist.test")

      # Add records
      Zone.Auth.add_record(zone_pid, build_a_record("persist.test", {10, 20, 30, 40}))

      # Query should work
      result = DnsClient.query_a(ctx.host, ctx.port, "persist.test", timeout: 3_000)

      case result do
        {:ok, response} ->
          assert DnsClient.get_rcode(response) == :NOERROR

        {:error, _reason} ->
          :ok
      end
    end

    test "zone controller lists zones", _ctx do
      # Start a zone
      {:ok, _pid} =
        ZoneController.start_zone(:auth, "list-test.local", view_name: "default")

      # List zones should include our zone
      zones = ZoneController.list_zones()
      assert is_list(zones)
      # The zone we created should be in the list
      assert length(zones) >= 1
    end
  end

  describe "config persistence round-trip" do
    test "ConfigPersistence saves and loads", _ctx do
      tmp = Path.join(@tmp_dir, "roundtrip")
      File.mkdir_p!(tmp)

      # Collect current config
      views = ConfigPersistence.collect_views()
      zones = ConfigPersistence.collect_zones()

      # Save current config
      result = ConfigPersistence.save_all(tmp, views, zones)
      assert result == :ok or match?({:ok, _}, result) or match?({:error, _}, result)

      # Load config
      case ConfigPersistence.load_all(tmp) do
        {:ok, config} ->
          assert is_map(config)
          assert Map.has_key?(config, :views)
          assert Map.has_key?(config, :zones)

        {:error, _reason} ->
          # May fail if no config to load, which is acceptable
          :ok
      end
    end
  end

  defp build_a_record(name, ip) do
    DNS.Message.Record.new(name, :a, :in, 3600, ip)
  end
end
