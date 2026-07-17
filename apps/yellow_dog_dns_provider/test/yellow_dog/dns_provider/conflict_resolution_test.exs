defmodule YellowDog.DnsProvider.ConflictResolutionTest do
  use ExUnit.Case, async: false

  alias YellowDog.DnsProvider
  alias YellowDog.DnsProvider.ConflictFake

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

  test "use_cloud rejects a conflict RR type outside the fixed atom allowlist" do
    configure_conflict(:cloudflare, type: "ANY")

    assert {:error, :invalid} = apply(DnsProvider, :resolve_conflict, ["conflict-1", :use_cloud])

    refute Enum.any?(ConflictFake.take_calls(), fn {name, _args} ->
             name in [:get_rrset, :put_rrset, :delete_rrset, :reload_zone]
           end)
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
    conflict = %{
      id: "conflict-1",
      provider_name: "cf-main",
      zone: @zone,
      owner: @owner,
      type: Keyword.get(overrides, :type, "A"),
      local_records: [%{owner: @owner, type: "A", ttl: 60, rdata: "192.0.2.1"}],
      remote_records: [%{owner: @owner, type: "A", ttl: 60, rdata: "192.0.2.2"}]
    }

    ConflictFake.configure(%{
      configs: [%{name: "cf-main", type: provider_type, enabled: true}],
      conflicts: %{"cf-main" => [conflict]},
      zones: %{{@view, @zone} => %{zone_type: :auth}},
      rrsets: %{{@view, @zone, @owner, :a} => [%{ttl: 60, rdata: "192.0.2.1"}]},
      responses: Keyword.get(overrides, :responses, %{})
    })
  end
end
