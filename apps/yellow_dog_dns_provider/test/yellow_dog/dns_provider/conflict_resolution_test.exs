defmodule YellowDog.DnsProvider.ConflictResolutionTest do
  use ExUnit.Case, async: false

  alias YellowDog.DnsProvider
  alias YellowDog.DnsProvider.{Config, ConflictFake, SyncEngine}
  alias YellowDog.DnsProvider.Provider.Cloudflare

  @view "default"
  @zone "example.test"
  @owner "www"

  setup do
    previous = Application.get_env(:yellow_dog_dns_provider, DnsProvider)

    Application.put_env(:yellow_dog_dns_provider, DnsProvider,
      provider_store: ConflictFake.Store,
      zone_store: ConflictFake.ZoneStore,
      zone_controller: ConflictFake.ZoneController,
      sync_engine: ConflictFake.SyncEngine
    )

    start_supervised!(ConflictFake)

    on_exit(fn ->
      if previous do
        Application.put_env(:yellow_dog_dns_provider, DnsProvider, previous)
      else
        Application.delete_env(:yellow_dog_dns_provider, DnsProvider)
      end
    end)

    :ok
  end

  test "use_cloud applies a Cloudflare remote RRset before deleting its marker" do
    configure_conflict(:cloudflare)

    assert :ok = apply(DnsProvider, :resolve_conflict, ["conflict-1", :use_cloud])

    assert ConflictFake.snapshot().rrsets[{@view, @zone, @owner, :a}] == [
             %{ttl: 60, rdata: "192.0.2.2"}
           ]

    assert ConflictFake.snapshot().conflicts["cf-main"] == []

    assert [
             {:list_configs, []},
             {:list_conflicts, ["cf-main"]},
             {:get_config, ["cf-main"]},
             {:get_zone, ["default", "example.test"]},
             {:get_rrset, ["default", "example.test", "www", :a]},
             {:put_rrset,
              ["default", "example.test", "www", :a, [%{ttl: 60, rdata: "192.0.2.2"}]]},
             {:reload_zone, ["default", :auth, "example.test", []]},
             {:delete_conflict, ["cf-main", "conflict-1"]}
           ] = ConflictFake.take_calls()
  end

  test "use_cloud supports stored Route53 conflicts without remote calls" do
    configure_conflict(:route53)

    assert :ok = apply(DnsProvider, :resolve_conflict, ["conflict-1", :use_cloud])

    refute Enum.any?(ConflictFake.take_calls(), fn {name, _args} -> name == :resolve_conflict end)
  end

  test "use_cloud replaces only the conflicted record and preserves sibling A records" do
    local = %{owner: @owner, type: "A", ttl: 300, rdata: "192.0.2.1"}
    remote = %{owner: @owner, type: "A", ttl: 60, rdata: "192.0.2.2"}

    old_rrset = [
      %{ttl: 300, rdata: "192.0.2.9"},
      %{ttl: 300, rdata: "192.0.2.1"},
      %{ttl: 300, rdata: "192.0.2.9"}
    ]

    configure_conflict(:cloudflare,
      local_records: [local],
      remote_records: [remote],
      rrset: old_rrset
    )

    assert :ok = DnsProvider.resolve_conflict("conflict-1", :use_cloud)

    assert ConflictFake.snapshot().rrsets[{@view, @zone, @owner, :a}] == [
             %{ttl: 60, rdata: "192.0.2.2"},
             %{ttl: 60, rdata: "192.0.2.9"}
           ]
  end

  test "use_cloud restores the complete prior RRset when activation fails" do
    old_rrset = [
      %{ttl: 300, rdata: "192.0.2.1"},
      %{ttl: 300, rdata: "192.0.2.9"}
    ]

    configure_conflict(:cloudflare,
      rrset: old_rrset,
      responses: %{reload_zone: [{:error, :reload_failed}, :ok]}
    )

    assert {:error, :apply_failed} =
             DnsProvider.resolve_conflict("conflict-1", :use_cloud)

    assert ConflictFake.snapshot().rrsets[{@view, @zone, @owner, :a}] == old_rrset
  end

  test "provider-qualified keep_remote remains compatible with ID-only resolution" do
    configure_conflict(:cloudflare)

    assert :ok = DnsProvider.resolve_conflict("cf-main", "conflict-1", :keep_remote)
    assert ConflictFake.snapshot().conflicts["cf-main"] == []
  end

  test "use_cloud restores and reloads the original RRset after local activation fails" do
    configure_conflict(:cloudflare, responses: %{reload_zone: [{:error, :reload_failed}, :ok]})

    assert {:error, :apply_failed} =
             apply(DnsProvider, :resolve_conflict, ["conflict-1", :use_cloud])

    assert ConflictFake.snapshot().rrsets[{@view, @zone, @owner, :a}] == [
             %{ttl: 60, rdata: "192.0.2.1"}
           ]

    assert [conflict] = ConflictFake.snapshot().conflicts["cf-main"]
    assert conflict.id == "conflict-1"
  end

  test "use_cloud reports rollback_failed when restored activation fails" do
    configure_conflict(:cloudflare,
      responses: %{reload_zone: [{:error, :reload_failed}, {:error, :rollback_reload_failed}]}
    )

    assert {:error, :rollback_failed} =
             apply(DnsProvider, :resolve_conflict, ["conflict-1", :use_cloud])
  end

  test "Cloudflare use_local verifies the provider change before deleting the marker" do
    configure_conflict(:cloudflare)

    assert :ok = apply(DnsProvider, :resolve_conflict, ["conflict-1", :use_local])

    assert [
             {:list_configs, []},
             {:list_conflicts, ["cf-main"]},
             {:get_config, ["cf-main"]},
             {:get_zone, ["default", "example.test"]},
             {:resolve_conflict, ["cf-main", _conflict, 5_000]},
             {:delete_conflict, ["cf-main", "conflict-1"]}
           ] = ConflictFake.take_calls()
  end

  test "use_local preserves stable remote zone mapping errors" do
    for reason <- [:not_found, :conflict, :unsupported] do
      configure_conflict(:cloudflare, responses: %{resolve_conflict: [{:error, reason}]})

      assert {:error, ^reason} = DnsProvider.resolve_conflict("conflict-1", :use_local)
      assert [_conflict] = ConflictFake.snapshot().conflicts["cf-main"]

      refute Enum.any?(ConflictFake.take_calls(), fn {name, _args} -> name == :delete_conflict end)
    end
  end

  test "Route53 use_local is unsupported before any remote engine call" do
    configure_conflict(:route53)

    assert {:error, :unsupported} =
             apply(DnsProvider, :resolve_conflict, ["conflict-1", :use_local])

    refute Enum.any?(ConflictFake.take_calls(), fn {name, _args} -> name == :resolve_conflict end)
  end

  test "use_local leaves the marker in place after remote rejection" do
    configure_conflict(:cloudflare, responses: %{resolve_conflict: [{:error, :remote_failed}]})

    assert {:error, :apply_failed} =
             apply(DnsProvider, :resolve_conflict, ["conflict-1", :use_local])

    assert [_conflict] = ConflictFake.snapshot().conflicts["cf-main"]
    refute Enum.any?(ConflictFake.take_calls(), fn {name, _args} -> name == :delete_conflict end)
  end

  test "marker deletion failure retains an applied conflict for idempotent retry" do
    configure_conflict(:cloudflare, responses: %{delete_conflict: [{:error, :delete_failed}]})

    assert {:error, :apply_failed} =
             apply(DnsProvider, :resolve_conflict, ["conflict-1", :use_cloud])

    assert [_conflict] = ConflictFake.snapshot().conflicts["cf-main"]
    assert :ok = apply(DnsProvider, :resolve_conflict, ["conflict-1", :use_cloud])
    assert ConflictFake.snapshot().conflicts["cf-main"] == []
  end

  test "Cloudflare use_local retry does not duplicate an accepted remote mutation" do
    ensure_provider_registry()
    remote = start_supervised!({Agent, fn -> remote_cloudflare_state() end})
    owner = self()

    req =
      Req.new(
        base_url: "https://api.cloudflare.test/client/v4",
        adapter: cloudflare_stateful_adapter(remote, owner)
      )

    {:ok, config} =
      Config.new(%{
        name: "cf-main",
        type: :cloudflare,
        zones: [@zone],
        credentials: %{api_token: "test-token", req: req},
        sync_interval: 3600,
        conflict_strategy: :manual,
        enabled: true
      })

    start_supervised!({SyncEngine, config: config, provider_module: Cloudflare})

    Application.put_env(:yellow_dog_dns_provider, DnsProvider,
      provider_store: ConflictFake.Store,
      zone_store: ConflictFake.ZoneStore,
      zone_controller: ConflictFake.ZoneController,
      sync_engine: SyncEngine
    )

    configure_real_cloudflare_conflict()

    assert {:error, :apply_failed} =
             DnsProvider.resolve_conflict("conflict-1", :use_local)

    assert %{posts: 1, deletes: 1} = Agent.get(remote, & &1)
    assert [_conflict] = ConflictFake.snapshot().conflicts["cf-main"]

    assert :ok = DnsProvider.resolve_conflict("conflict-1", :use_local)

    assert %{posts: 1, deletes: 1} = Agent.get(remote, & &1)
    assert ConflictFake.snapshot().conflicts["cf-main"] == []

    assert_received {:remote_write, :delete,
                     "/client/v4/zones/zone-retry/dns_records/remote-record"}

    assert_received {:remote_write, :post, "/client/v4/zones/zone-retry/dns_records"}
  end

  test "use_cloud rejects a conflict RR type outside the fixed atom allowlist" do
    configure_conflict(:cloudflare, type: "ANY")

    assert {:error, :invalid} = apply(DnsProvider, :resolve_conflict, ["conflict-1", :use_cloud])

    refute Enum.any?(ConflictFake.take_calls(), fn {name, _args} ->
             name in [:get_rrset, :put_rrset, :delete_rrset, :reload_zone]
           end)
  end

  test "rejects disabled, rebound, and type-mismatched cloud mirrors before applying either side" do
    cases = [
      {%{enabled: false, connector_name: "cf-main", provider: :cloudflare}, :unsupported},
      {%{enabled: true, connector_name: "other-provider", provider: :cloudflare}, :conflict},
      {%{enabled: true, connector_name: "cf-main", provider: :route53}, :conflict}
    ]

    for {mirror, expected_error} <- cases,
        resolution <- [:use_cloud, :use_local] do
      configure_conflict(:cloudflare, cloud_mirror: mirror)

      assert {:error, ^expected_error} =
               DnsProvider.resolve_conflict("conflict-1", resolution)

      refute Enum.any?(ConflictFake.take_calls(), fn {name, _args} ->
               name in [
                 :get_rrset,
                 :put_rrset,
                 :delete_rrset,
                 :reload_zone,
                 :resolve_conflict,
                 :delete_conflict
               ]
             end)
    end
  end

  test "use_cloud canonicalizes stored zone and owner identity before Store calls" do
    configure_conflict(:cloudflare)

    conflict = %{
      id: "conflict-1",
      provider_name: "cf-main",
      zone: "Example.Test.",
      owner: "WWW.",
      type: "A",
      local_records: [%{owner: "WWW.", type: "A", ttl: 60, rdata: "192.0.2.1"}],
      remote_records: [%{owner: "WWW.", type: "A", ttl: 60, rdata: "192.0.2.2"}]
    }

    ConflictFake.configure(%{conflicts: %{"cf-main" => [conflict]}})

    assert :ok = DnsProvider.resolve_conflict("conflict-1", :use_cloud)

    assert [
             {:list_configs, []},
             {:list_conflicts, ["cf-main"]},
             {:get_config, ["cf-main"]},
             {:get_zone, ["default", "example.test"]},
             {:get_rrset, ["default", "example.test", "www", :a]},
             {:put_rrset, ["default", "example.test", "www", :a, _rrset]},
             {:reload_zone, ["default", :auth, "example.test", []]},
             {:delete_conflict, ["cf-main", "conflict-1"]}
           ] = ConflictFake.take_calls()
  end

  defp configure_conflict(provider_type, overrides \\ []) do
    local_records =
      Keyword.get(overrides, :local_records, [
        %{owner: @owner, type: "A", ttl: 60, rdata: "192.0.2.1"}
      ])

    remote_records =
      Keyword.get(overrides, :remote_records, [
        %{owner: @owner, type: "A", ttl: 60, rdata: "192.0.2.2"}
      ])

    conflict = %{
      id: "conflict-1",
      provider_name: "cf-main",
      zone: @zone,
      owner: @owner,
      type: Keyword.get(overrides, :type, "A"),
      local_records: local_records,
      remote_records: remote_records
    }

    cloud_mirror =
      Keyword.get(overrides, :cloud_mirror, %{
        enabled: true,
        connector_name: "cf-main",
        provider: provider_type
      })

    ConflictFake.configure(%{
      configs: [%{name: "cf-main", type: provider_type, enabled: true}],
      conflicts: %{"cf-main" => [conflict]},
      zones: %{{@view, @zone} => %{zone_type: :auth, cloud_mirror: cloud_mirror}},
      rrsets: %{
        {@view, @zone, @owner, :a} =>
          Keyword.get(overrides, :rrset, [%{ttl: 60, rdata: "192.0.2.1"}])
      },
      responses: Keyword.get(overrides, :responses, %{})
    })
  end

  defp configure_real_cloudflare_conflict do
    owner = "www.example.test."

    conflict = %{
      id: "conflict-1",
      provider_name: "cf-main",
      zone: @zone,
      owner: owner,
      type: "A",
      local_records: [%{owner: owner, type: "A", ttl: 60, rdata: "192.0.2.1"}],
      remote_records: [%{owner: owner, type: "A", ttl: 60, rdata: "192.0.2.2"}]
    }

    ConflictFake.configure(%{
      configs: [%{name: "cf-main", type: :cloudflare, enabled: true}],
      conflicts: %{"cf-main" => [conflict]},
      zones: %{
        {@view, @zone} => %{
          zone_type: :auth,
          cloud_mirror: %{
            enabled: true,
            connector_name: "cf-main",
            provider: :cloudflare
          }
        }
      },
      responses: %{delete_conflict: [{:error, :delete_failed}]}
    })
  end

  defp ensure_provider_registry do
    case Registry.start_link(keys: :unique, name: YellowDog.DnsProvider.Registry) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  defp remote_cloudflare_state do
    %{
      records: [
        %{
          "id" => "remote-record",
          "name" => "www.example.test",
          "type" => "A",
          "ttl" => 60,
          "content" => "192.0.2.2"
        }
      ],
      posts: 0,
      deletes: 0
    }
  end

  defp cloudflare_stateful_adapter(remote, owner) do
    fn request ->
      response = cloudflare_stateful_response(request, remote, owner)
      {request, response}
    end
  end

  defp cloudflare_stateful_response(
         %{method: :get, url: %{path: "/client/v4/zones"}},
         _remote,
         _owner
       ) do
    Req.Response.new(
      status: 200,
      body: %{"result" => [%{"name" => @zone, "id" => "zone-retry"}]}
    )
  end

  defp cloudflare_stateful_response(
         %{method: :get, url: %{path: "/client/v4/zones/zone-retry/dns_records"}},
         remote,
         _owner
       ) do
    records = Agent.get(remote, & &1.records)

    Req.Response.new(
      status: 200,
      body: %{"result" => records, "result_info" => %{"total_pages" => 1}}
    )
  end

  defp cloudflare_stateful_response(
         %{
           method: :delete,
           url: %{path: "/client/v4/zones/zone-retry/dns_records/remote-record" = path}
         },
         remote,
         owner
       ) do
    Agent.update(remote, fn state ->
      %{state | records: [], deletes: state.deletes + 1}
    end)

    send(owner, {:remote_write, :delete, path})
    Req.Response.new(status: 200, body: %{"success" => true})
  end

  defp cloudflare_stateful_response(
         %{method: :post, url: %{path: "/client/v4/zones/zone-retry/dns_records" = path}} =
           request,
         remote,
         owner
       ) do
    body = Jason.decode!(request.body)

    Agent.update(remote, fn state ->
      record = %{
        "id" => "local-record",
        "name" => body["name"],
        "type" => body["type"],
        "ttl" => body["ttl"],
        "content" => body["content"]
      }

      %{state | records: [record], posts: state.posts + 1}
    end)

    send(owner, {:remote_write, :post, path})
    Req.Response.new(status: 200, body: %{"success" => true})
  end

  defp cloudflare_stateful_response(request, _remote, _owner) do
    Req.Response.new(
      status: 500,
      body: %{"unexpected" => {request.method, request.url.path}}
    )
  end
end
