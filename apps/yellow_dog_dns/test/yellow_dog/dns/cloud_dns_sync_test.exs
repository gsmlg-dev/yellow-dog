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
      stop_dynamic_supervisor(zc_pid)
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

    test_pid = self()

    assert {:ok, %{records_synced: 3, provider: :cloudflare}} =
             CloudDnsSync.sync_zone_from_cloud(view_name, zone_name,
               request_fun: &cloudflare_fixture/1,
               cache_invalidator: fn invalidated_view, invalidated_zone ->
                 send(test_pid, {:cache_invalidated, invalidated_view, invalidated_zone})
                 :ok
               end
             )

    assert_received {:cache_invalidated, ^view_name, ^zone_name}

    assert {:ok, rrsets} = Zone.list_records(view_name, zone_name)
    assert Enum.any?(rrsets, &(&1.owner == "www.#{zone_name}" and &1.type == :a))
    assert Enum.any?(rrsets, &(&1.owner == zone_name and &1.type == :txt))
    assert Enum.any?(rrsets, &(&1.owner == zone_name and &1.type == :mx))

    records = Auth.get_records(pid, "www.#{zone_name}", :a)
    assert [%{data: %{data: {192, 0, 2, 10}}, ttl: 120}] = records
  end

  test "pulls Route 53 records using the global service signing region" do
    view_name = "sync_view_#{System.unique_integer([:positive])}"
    zone_name = "gsmlg.net"

    cloud_mirror = %{
      enabled: true,
      connector_name: "aws-prod",
      provider: :route53,
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
        name: "aws-prod",
        type: :route53,
        credentials: %{
          access_key_id: "AKIATEST",
          secret_access_key: "route53-secret",
          region: "global"
        },
        enabled: true
      })

    {:ok, pid} = ZoneController.start_zone(:auth, zone_name, view_name: view_name)

    assert Auth.get_records(pid, "www.#{zone_name}", :a) == []

    assert {:ok, %{records_synced: 4, provider: :route53}} =
             CloudDnsSync.sync_zone_from_cloud(view_name, zone_name,
               request_fun: &route53_fixture/1,
               request_time: ~U[2026-06-24 00:00:00Z]
             )

    assert {:ok, rrsets} = Zone.list_records(view_name, zone_name)
    assert Enum.any?(rrsets, &(&1.owner == "www.#{zone_name}" and &1.type == :a))
    assert Enum.any?(rrsets, &(&1.owner == zone_name and &1.type == :txt))
    assert Enum.any?(rrsets, &(&1.owner == zone_name and &1.type == :mx))
    assert Enum.any?(rrsets, &(&1.owner == "_sip._tcp.#{zone_name}" and &1.type == :srv))

    records = Auth.get_records(pid, "www.#{zone_name}", :a)
    assert [%{data: %{data: {198, 51, 100, 25}}, ttl: 60}] = records
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

  defp route53_fixture(opts) do
    assert opts[:method] == :get
    assert {"host", "route53.amazonaws.com"} in opts[:headers]
    assert {"x-amz-date", "20260624T000000Z"} in opts[:headers]

    assert Enum.any?(opts[:headers], fn
             {"authorization", "AWS4-HMAC-SHA256 " <> rest} ->
               rest =~ "Credential=AKIATEST/20260624/us-east-1/route53/aws4_request" and
                 rest =~ "SignedHeaders=" and rest =~ "Signature="

             _header ->
               false
           end)

    case opts[:url] do
      "https://route53.amazonaws.com/2013-04-01/hostedzonesbyname?dnsname=gsmlg.net.&maxitems=1" ->
        {:ok, %{status: 200, body: route53_hosted_zones_xml()}}

      "https://route53.amazonaws.com/2013-04-01/hostedzone/Z123456789/rrset?maxitems=100" ->
        {:ok, %{status: 200, body: route53_rrsets_xml()}}
    end
  end

  defp stop_dynamic_supervisor(pid) do
    if Process.alive?(pid) do
      DynamicSupervisor.stop(pid)
    end
  catch
    :exit, _reason -> :ok
  end

  defp route53_hosted_zones_xml do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <ListHostedZonesByNameResponse xmlns="https://route53.amazonaws.com/doc/2013-04-01/">
      <HostedZones>
        <HostedZone>
          <Id>/hostedzone/Z123456789</Id>
          <Name>gsmlg.net.</Name>
        </HostedZone>
      </HostedZones>
      <IsTruncated>false</IsTruncated>
      <MaxItems>1</MaxItems>
    </ListHostedZonesByNameResponse>
    """
  end

  defp route53_rrsets_xml do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <ListResourceRecordSetsResponse xmlns="https://route53.amazonaws.com/doc/2013-04-01/">
      <ResourceRecordSets>
        <ResourceRecordSet>
          <Name>gsmlg.net.</Name>
          <Type>SOA</Type>
          <TTL>900</TTL>
          <ResourceRecords>
            <ResourceRecord>
              <Value>ns-2048.awsdns-64.net. hostmaster.awsdns.com. 1 7200 900 1209600 86400</Value>
            </ResourceRecord>
          </ResourceRecords>
        </ResourceRecordSet>
        <ResourceRecordSet>
          <Name>www.gsmlg.net.</Name>
          <Type>A</Type>
          <TTL>60</TTL>
          <ResourceRecords>
            <ResourceRecord><Value>198.51.100.25</Value></ResourceRecord>
          </ResourceRecords>
        </ResourceRecordSet>
        <ResourceRecordSet>
          <Name>gsmlg.net.</Name>
          <Type>TXT</Type>
          <TTL>300</TTL>
          <ResourceRecords>
            <ResourceRecord><Value>"route53 mirror"</Value></ResourceRecord>
          </ResourceRecords>
        </ResourceRecordSet>
        <ResourceRecordSet>
          <Name>gsmlg.net.</Name>
          <Type>MX</Type>
          <TTL>300</TTL>
          <ResourceRecords>
            <ResourceRecord><Value>10 mail.gsmlg.net.</Value></ResourceRecord>
          </ResourceRecords>
        </ResourceRecordSet>
        <ResourceRecordSet>
          <Name>_sip._tcp.gsmlg.net.</Name>
          <Type>SRV</Type>
          <TTL>300</TTL>
          <ResourceRecords>
            <ResourceRecord><Value>0 5 5060 sip.gsmlg.net.</Value></ResourceRecord>
          </ResourceRecords>
        </ResourceRecordSet>
      </ResourceRecordSets>
      <IsTruncated>false</IsTruncated>
      <MaxItems>100</MaxItems>
    </ListResourceRecordSetsResponse>
    """
  end
end
