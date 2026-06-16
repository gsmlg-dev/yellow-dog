defmodule YellowDog.Dns.CloudDnsSyncTest do
  use ExUnit.Case, async: false

  alias YellowDog.Dns.CloudDnsSync
  alias YellowDog.Dns.Zone.Auth
  alias YellowDog.Dns.ZoneController
  alias YellowDog.Store.Backend
  alias YellowDog.Store.Backend.Ets, as: EtsBackend
  alias YellowDog.Store.Provider
  alias YellowDog.Store.Zone

  setup do
    previous_backend = Backend.active()

    Backend.set_active(EtsBackend)
    EtsBackend.create_table()
    :ets.delete_all_objects(EtsBackend.table())

    for name <- [YellowDog.Dns.ZoneRegistry] do
      if pid = Process.whereis(name), do: GenServer.stop(pid, :normal, 500)
      start_supervised!({Registry, keys: :unique, name: name})
    end

    zc_pid =
      case DynamicSupervisor.start_link(strategy: :one_for_one, name: ZoneController) do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
      end

    on_exit(fn ->
      if Process.alive?(zc_pid), do: DynamicSupervisor.stop(zc_pid)
      :ets.delete_all_objects(EtsBackend.table())
      Backend.set_active(previous_backend)
    end)

    :ok
  end

  test "pulls Cloudflare records into Store and reloads the running auth zone" do
    view_name = "sync_view_#{System.unique_integer([:positive])}"
    zone_name = "gsmlg.dev"

    cloud_mirror = %{
      enabled: true,
      connector_name: "cf-main",
      provider: :cloudflare,
      zone_id: "",
      direction: :bidirectional,
      conflict_strategy: :local_wins
    }

    :ok =
      Zone.create_zone(view_name, zone_name, Zone.default_soa(zone_name),
        cloud_mirror: cloud_mirror
      )

    :ok =
      Provider.put_config(%{
        name: "cf-main",
        type: :cloudflare,
        credentials: %{api_token: "test-token"},
        enabled: true
      })

    {:ok, pid} = ZoneController.start_zone(:auth, zone_name, view_name: view_name)

    assert Auth.get_records(pid, "www.#{zone_name}", :a) == []

    assert {:ok, %{records_synced: 3, provider: :cloudflare}} =
             CloudDnsSync.sync_zone_from_cloud(view_name, zone_name,
               request_fun: &cloudflare_fixture/1
             )

    assert {:ok, rrsets} = Zone.list_records(view_name, zone_name)
    assert Enum.any?(rrsets, &(&1.owner == "www.#{zone_name}" and &1.type == :a))
    assert Enum.any?(rrsets, &(&1.owner == zone_name and &1.type == :txt))
    assert Enum.any?(rrsets, &(&1.owner == zone_name and &1.type == :mx))

    records = Auth.get_records(pid, "www.#{zone_name}", :a)
    assert [%{data: %{data: {192, 0, 2, 10}}, ttl: 120}] = records
  end

  defp cloudflare_fixture(opts) do
    assert opts[:method] == :get
    assert {"authorization", "Bearer test-token"} in opts[:headers]

    case {opts[:url], opts[:params]} do
      {"https://api.cloudflare.com/client/v4/zones", params} ->
        assert params[:name] == "gsmlg.dev"

        {:ok,
         %{
           status: 200,
           body: %{
             "success" => true,
             "result" => [%{"id" => "zone-id", "name" => "gsmlg.dev"}]
           }
         }}

      {"https://api.cloudflare.com/client/v4/zones/zone-id/dns_records", params} ->
        assert params[:page] == 1

        {:ok,
         %{
           status: 200,
           body: %{
             "success" => true,
             "result" => [
               %{
                 "type" => "A",
                 "name" => "www.gsmlg.dev",
                 "content" => "192.0.2.10",
                 "ttl" => 120
               },
               %{
                 "type" => "TXT",
                 "name" => "gsmlg.dev",
                 "content" => "cloud mirror",
                 "ttl" => 1
               },
               %{
                 "type" => "MX",
                 "name" => "gsmlg.dev",
                 "content" => "mail.gsmlg.dev",
                 "priority" => 10,
                 "ttl" => 300
               }
             ],
             "result_info" => %{"page" => 1, "total_pages" => 1}
           }
         }}
    end
  end
end
