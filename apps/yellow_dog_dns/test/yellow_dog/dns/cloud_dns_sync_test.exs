defmodule YellowDog.Dns.CloudDnsSyncTest do
  use ExUnit.Case, async: false

  alias YellowDog.Dns.CloudDnsSync
  alias YellowDog.Dns.Zone.Auth
  alias YellowDog.Dns.ZoneController
  alias YellowDog.Store.Backend
  alias YellowDog.Store.Backend.Ets, as: EtsBackend
  alias YellowDog.Store.EventBridge
  alias YellowDog.Store.Provider
  alias YellowDog.Store.Zone

  defmodule ReplacementStore do
    use Agent

    def start_link(_opts), do: Agent.start_link(fn -> %{} end, name: __MODULE__)
    def configure(state), do: Agent.update(__MODULE__, &Map.merge(&1, state))
    def calls, do: Agent.get(__MODULE__, &Enum.reverse(Map.get(&1, :calls, [])))

    def get_zone(_view_name, _zone_name), do: call(:get_zone, &{{:ok, &1.zone}, &1})
    def get_config(_provider_id), do: call(:get_config, &{{:ok, &1.provider}, &1})

    def replace_records(_view_name, _zone_name, records) do
      call({:replace_records, records}, fn state ->
        [result | remaining] = state.replace_results
        {result, %{state | replace_results: remaining}}
      end)
    end

    def reload_zone(_view_name, :auth, _zone_name, []) do
      call(:reload_zone, fn state ->
        [result | remaining] = state.reload_results
        {result, %{state | reload_results: remaining}}
      end)
    end

    def cache_invalidated(_view_name, _zone_name) do
      result =
        call(:cache_invalidated, fn state ->
          [result | remaining] = Map.get(state, :cache_results, [:ok])
          {result, Map.put(state, :cache_results, remaining)}
        end)

      case result do
        {:raise, message} -> raise message
        {:exit, reason} -> exit(reason)
        result -> result
      end
    end

    def fetched, do: call(:fetched, &{:ok, &1})

    defp call(label, fun) do
      Agent.get_and_update(__MODULE__, fn state ->
        {result, state} = fun.(state)
        {result, Map.update(state, :calls, [label], &[label | &1])}
      end)
    end
  end

  setup do
    previous_backend = Backend.active()

    Backend.set_active(EtsBackend)
    EtsBackend.create_table()
    :ets.delete_all_objects(EtsBackend.table())

    {:ok, event_subscription} = EventBridge.subscribe("dns:view:*")

    for name <- [YellowDog.Dns.ZoneRegistry] do
      if pid = Process.whereis(name), do: GenServer.stop(pid, :normal, 500)
      start_supervised!({Registry, keys: :unique, name: name})
    end

    {zc_pid, owns_zone_controller?} =
      case DynamicSupervisor.start_link(strategy: :one_for_one, name: ZoneController) do
        {:ok, pid} -> {pid, true}
        {:error, {:already_started, pid}} -> {pid, false}
      end

    on_exit(fn ->
      if owns_zone_controller?, do: stop_dynamic_supervisor(zc_pid)
      EventBridge.unsubscribe(event_subscription)
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

    assert :ok =
             Zone.put_rrset(view_name, zone_name, "stale.#{zone_name}", :a, [
               %{address: "192.0.2.99", ttl: 60}
             ])

    test_pid = self()

    assert {:ok, %{records_synced: 4, provider: :cloudflare}} =
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
    refute Enum.any?(rrsets, &(&1.owner == "stale.#{zone_name}" and &1.type == :a))

    records = Auth.get_records(pid, "www.#{zone_name}", :a)
    assert [%{data: %{data: {192, 0, 2, 10}}, ttl: 120}] = records
    drain_event_bridge()
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
    drain_event_bridge()
  end

  test "fetches complete remote records before replacement, then reloads and invalidates caches" do
    start_supervised!(ReplacementStore)

    previous = [%{owner: "stale.gsmlg.dev", type: :a, rrset: [%{address: "192.0.2.99", ttl: 60}]}]

    ReplacementStore.configure(%{
      zone: cloud_zone(),
      provider: cloudflare_provider(),
      replace_results: [{:ok, %{previous: previous, changed_count: 3}}],
      reload_results: [:ok],
      cache_results: [:ok]
    })

    assert {:ok, %{provider: :cloudflare, records_synced: 3}} =
             CloudDnsSync.sync_zone_from_cloud("default", "gsmlg.dev",
               request_fun: &recording_cloudflare_fixture/1,
               zone_store: ReplacementStore,
               provider_store: ReplacementStore,
               zone_controller: ReplacementStore,
               cache_invalidator: &ReplacementStore.cache_invalidated/2
             )

    calls = ReplacementStore.calls()
    replace_index = Enum.find_index(calls, &match?({:replace_records, _}, &1))
    assert Enum.count(Enum.take(calls, replace_index), &(&1 == :fetched)) == 2
    assert calls |> Enum.drop_while(&(&1 != :reload_zone)) |> hd() == :reload_zone
    assert List.last(calls) == :cache_invalidated
  end

  test "sanitizes replacement errors while preserving Store rollback failure" do
    start_supervised!(ReplacementStore)

    for {replace_result, expected} <- [
          {{:error, {:replace_failed, {:credential, "replace-secret"}}}, :apply_failed},
          {{:error,
            {:rollback_failed, {:credential, "apply-secret"}, {:credential, "rollback-secret"}}},
           :rollback_failed}
        ] do
      ReplacementStore.configure(%{
        zone: cloud_zone(),
        provider: cloudflare_provider(),
        replace_results: [replace_result],
        reload_results: [],
        calls: []
      })

      result =
        CloudDnsSync.sync_zone_from_cloud("default", "gsmlg.dev",
          request_fun: &recording_cloudflare_fixture/1,
          zone_store: ReplacementStore,
          provider_store: ReplacementStore,
          zone_controller: ReplacementStore
        )

      assert result == {:error, expected}
      refute inspect(result) =~ "secret"
      refute :reload_zone in ReplacementStore.calls()
    end
  end

  test "restores the prior replacement and reloads it when activation fails" do
    start_supervised!(ReplacementStore)

    previous = [%{owner: "stale.gsmlg.dev", type: :a, rrset: [%{address: "192.0.2.99", ttl: 60}]}]

    ReplacementStore.configure(%{
      zone: cloud_zone(),
      provider: cloudflare_provider(),
      replace_results: [
        {:ok, %{previous: previous, changed_count: 3}},
        {:ok, %{previous: [], changed_count: 3}}
      ],
      reload_results: [{:error, :reload_failed}, :ok],
      cache_results: [:ok]
    })

    assert {:error, :apply_failed} =
             CloudDnsSync.sync_zone_from_cloud("default", "gsmlg.dev",
               request_fun: &recording_cloudflare_fixture/1,
               zone_store: ReplacementStore,
               provider_store: ReplacementStore,
               zone_controller: ReplacementStore,
               cache_invalidator: &ReplacementStore.cache_invalidated/2
             )

    assert [
             {:replace_records, _desired},
             :reload_zone,
             {:replace_records, ^previous},
             :reload_zone,
             :cache_invalidated
           ] =
             ReplacementStore.calls()
             |> activation_calls()
  end

  test "reports rollback failure when restored activation also fails" do
    start_supervised!(ReplacementStore)

    previous = [%{owner: "stale.gsmlg.dev", type: :a, rrset: [%{address: "192.0.2.99", ttl: 60}]}]

    ReplacementStore.configure(%{
      zone: cloud_zone(),
      provider: cloudflare_provider(),
      replace_results: [
        {:ok, %{previous: previous, changed_count: 3}},
        {:ok, %{previous: [], changed_count: 3}}
      ],
      reload_results: [{:error, :reload_failed}, {:error, :restored_reload_failed}],
      cache_results: []
    })

    assert {:error, :rollback_failed} =
             CloudDnsSync.sync_zone_from_cloud("default", "gsmlg.dev",
               request_fun: &recording_cloudflare_fixture/1,
               zone_store: ReplacementStore,
               provider_store: ReplacementStore,
               zone_controller: ReplacementStore,
               cache_invalidator: &ReplacementStore.cache_invalidated/2
             )

    assert [
             {:replace_records, _desired},
             :reload_zone,
             {:replace_records, ^previous},
             :reload_zone
           ] =
             ReplacementStore.calls()
             |> activation_calls()
  end

  test "restores and reactivates prior state when cache invalidation fails" do
    start_supervised!(ReplacementStore)

    previous = [%{owner: "stale.gsmlg.dev", type: :a, rrset: [%{address: "192.0.2.99", ttl: 60}]}]

    for invalidation_failure <- [
          {:error, {:cache_failed, "cache-secret"}},
          {:unexpected_cache_result, "cache-secret"},
          {:raise, "cache-secret"},
          {:exit, {:cache_failed, "cache-secret"}}
        ] do
      ReplacementStore.configure(%{
        zone: cloud_zone(),
        provider: cloudflare_provider(),
        replace_results: [
          {:ok, %{previous: previous, changed_count: 3}},
          {:ok, %{previous: [], changed_count: 3}}
        ],
        reload_results: [:ok, :ok],
        cache_results: [invalidation_failure, :ok],
        calls: []
      })

      result =
        CloudDnsSync.sync_zone_from_cloud("default", "gsmlg.dev",
          request_fun: &recording_cloudflare_fixture/1,
          zone_store: ReplacementStore,
          provider_store: ReplacementStore,
          zone_controller: ReplacementStore,
          cache_invalidator: &ReplacementStore.cache_invalidated/2
        )

      assert result == {:error, :apply_failed}
      refute inspect(result) =~ "secret"

      assert [
               {:replace_records, _desired},
               :reload_zone,
               :cache_invalidated,
               {:replace_records, ^previous},
               :reload_zone,
               :cache_invalidated
             ] =
               ReplacementStore.calls()
               |> activation_calls()
    end
  end

  test "reports rollback failure when cache compensation cannot restore records" do
    start_supervised!(ReplacementStore)

    previous = [%{owner: "stale.gsmlg.dev", type: :a, rrset: [%{address: "192.0.2.99", ttl: 60}]}]

    ReplacementStore.configure(%{
      zone: cloud_zone(),
      provider: cloudflare_provider(),
      replace_results: [
        {:ok, %{previous: previous, changed_count: 3}},
        {:error, {:restore_failed, "restore-secret"}}
      ],
      reload_results: [:ok],
      cache_results: [{:error, {:cache_failed, "cache-secret"}}]
    })

    result =
      CloudDnsSync.sync_zone_from_cloud("default", "gsmlg.dev",
        request_fun: &recording_cloudflare_fixture/1,
        zone_store: ReplacementStore,
        provider_store: ReplacementStore,
        zone_controller: ReplacementStore,
        cache_invalidator: &ReplacementStore.cache_invalidated/2
      )

    assert result == {:error, :rollback_failed}
    refute inspect(result) =~ "secret"

    assert [
             {:replace_records, _desired},
             :reload_zone,
             :cache_invalidated,
             {:replace_records, ^previous}
           ] =
             ReplacementStore.calls()
             |> activation_calls()
  end

  test "reports rollback failure when restored cache invalidation fails" do
    start_supervised!(ReplacementStore)

    previous = [%{owner: "stale.gsmlg.dev", type: :a, rrset: [%{address: "192.0.2.99", ttl: 60}]}]

    ReplacementStore.configure(%{
      zone: cloud_zone(),
      provider: cloudflare_provider(),
      replace_results: [
        {:ok, %{previous: previous, changed_count: 3}},
        {:ok, %{previous: [], changed_count: 3}}
      ],
      reload_results: [:ok, :ok],
      cache_results: [
        {:error, {:cache_failed, "initial-secret"}},
        {:error, {:cache_failed, "restore-secret"}}
      ]
    })

    result =
      CloudDnsSync.sync_zone_from_cloud("default", "gsmlg.dev",
        request_fun: &recording_cloudflare_fixture/1,
        zone_store: ReplacementStore,
        provider_store: ReplacementStore,
        zone_controller: ReplacementStore,
        cache_invalidator: &ReplacementStore.cache_invalidated/2
      )

    assert result == {:error, :rollback_failed}
    refute inspect(result) =~ "secret"

    assert [
             {:replace_records, _desired},
             :reload_zone,
             :cache_invalidated,
             {:replace_records, ^previous},
             :reload_zone,
             :cache_invalidated
           ] =
             ReplacementStore.calls()
             |> activation_calls()
  end

  defp cloud_zone do
    %{cloud_mirror: %{enabled: true, connector_name: "cf-main", zone_id: ""}}
  end

  defp cloudflare_provider do
    %{name: "cf-main", type: :cloudflare, credentials: %{api_token: "test-token"}, enabled: true}
  end

  defp recording_cloudflare_fixture(opts) do
    ReplacementStore.fetched()
    cloudflare_fixture(opts)
  end

  defp activation_calls(calls) do
    Enum.filter(calls, fn
      {:replace_records, _records} -> true
      call when call in [:reload_zone, :cache_invalidated] -> true
      _call -> false
    end)
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

  defp drain_event_bridge do
    EventBridge
    |> Process.whereis()
    |> :sys.get_state()

    :ok
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
