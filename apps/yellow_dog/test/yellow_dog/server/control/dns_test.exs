defmodule YellowDog.Server.Control.DnsTest do
  use ExUnit.Case, async: false

  alias YellowDog.Server.Control.Dispatcher
  alias YellowDog.Server.Control.Dns
  alias YellowDog.Server.Control.Revision
  alias YellowDog.Store.Backend
  alias YellowDog.Store.Backend.Ets, as: EtsBackend
  alias YellowDog.Store.Zone, as: StoreZone
  alias YellowDog.ServerDnsControlFake
  alias YellowDog.Sync.Digest
  alias YellowDog.Sync.Envelope
  alias YellowDog.Sync.Error
  alias YellowDog.Sync.Operation
  alias YellowDog.Sync.ServerOperation

  @observed_at "2026-07-16T00:00:00Z"
  @request_id "00000000-0000-0000-0000-000000000031"
  @idempotency_key "00000000-0000-0000-0000-00000000003c"
  @sent_at ~U[2026-07-16 00:00:00Z]
  @read_operations [
    "server.dns.views.list",
    "server.dns.zones.list",
    "server.dns.records.list",
    "server.dns.acls.list",
    "server.dns.providers.list",
    "server.dns.logs.list",
    "server.dns.metrics.get"
  ]
  @mutation_operations [
    "server.dns.views.create",
    "server.dns.views.update",
    "server.dns.views.delete",
    "server.dns.zones.create",
    "server.dns.zones.update",
    "server.dns.zones.delete",
    "server.dns.records.create",
    "server.dns.records.update",
    "server.dns.records.delete",
    "server.dns.acls.create",
    "server.dns.acls.update",
    "server.dns.acls.delete",
    "server.dns.providers.create",
    "server.dns.providers.update",
    "server.dns.providers.delete",
    "server.dns.zones.import",
    "server.dns.zones.sync",
    "server.dns.conflicts.resolve"
  ]

  setup do
    previous_dns = Application.get_env(:yellow_dog, Dns)
    previous_dispatcher = Application.get_env(:yellow_dog, Dispatcher)

    Application.put_env(:yellow_dog, Dns,
      view_manager: ServerDnsControlFake.ViewManager,
      zone_store: ServerDnsControlFake.ZoneStore,
      zone_controller: ServerDnsControlFake.ZoneController,
      acl_registry: ServerDnsControlFake.AclRegistry,
      acl_codec: ServerDnsControlFake.AclCodec,
      provider_store: ServerDnsControlFake.ProviderStore,
      provider_facade: ServerDnsControlFake.ProviderFacade,
      tasks: ServerDnsControlFake.Tasks,
      query_logger: ServerDnsControlFake.QueryLogger,
      metrics_collector: ServerDnsControlFake.MetricsCollector,
      clock: ServerDnsControlFake.Clock
    )

    Application.put_env(:yellow_dog, Dispatcher,
      adapters: %{dns: Dns},
      service_registry: YellowDog.ServerControlFake.ServiceRegistry,
      profile_resolver: YellowDog.ServerControlFake.ProfileResolver
    )

    start_supervised!(ServerDnsControlFake)
    start_supervised!(YellowDog.ServerControlFake)

    on_exit(fn ->
      restore_env(Dns, previous_dns)
      restore_env(Dispatcher, previous_dispatcher)
    end)

    :ok
  end

  test "projects active views without runtime process fields" do
    ServerDnsControlFake.configure(%{
      views: [{"external", self(), 20}, {"internal", self(), 10}],
      view_stats: %{
        views: %{
          "external" => %{match_clients: ["0.0.0.0/0"], recursion_enabled: false},
          "internal" => %{
            match_clients: ["10.0.0.0/8"],
            recursion_enabled: true,
            pid: self(),
            cache_path: "/var/lib/yellowdog/view-cache"
          }
        }
      }
    })

    assert {:ok, result} = Dns.dispatch("server.dns.views.list", %{})

    assert result ==
             list_result(
               [
                 %{
                   "view_name" => "external",
                   "match_clients" => ["0.0.0.0/0"],
                   "recursion" => false
                 },
                 %{
                   "view_name" => "internal",
                   "match_clients" => ["10.0.0.0/8"],
                   "recursion" => true
                 }
               ],
               result["revision"]
             )

    assert_valid_result("server.dns.views.list", result)
    refute inspect(result) =~ inspect(self())
    refute inspect(result) =~ "/var/lib/yellowdog"

    assert [{:view_manager, :list_control_views, []}, {:clock, :utc_now, []}] =
             ServerDnsControlFake.take_calls()
  end

  test "creates authoritative zones by persisting default SOA before starting the runtime" do
    ServerDnsControlFake.configure(%{views: [{"default", self(), 0}]})

    payload = %{zone_payload() | "zone_name" => "Example.Test."}

    assert {:ok, result} = Dns.dispatch("server.dns.zones.create", payload)
    assert_valid_result("server.dns.zones.create", result)
    assert result["resource"] == zone_payload()

    assert [
             {:view_manager, :list_control_views, []},
             {:zone_store, :get_zone, ["default", "example.test"]},
             {:zone_store, :default_soa, ["example.test"]},
             {:zone_store, :create_zone, ["default", "example.test", soa, []]},
             {:zone_controller, :start_zone, [:auth, "example.test", [view_name: "default"]]}
           ] = ServerDnsControlFake.take_calls()

    assert soa == %{mname: "ns1.example.test", rname: "hostmaster.example.test"}
  end

  test "rejects forward zone creation before any facade side effect" do
    assert {:error, %Error{code: :unsupported}} =
             Dns.dispatch("server.dns.zones.create", %{zone_payload() | "zone_type" => "forward"})

    assert [] = ServerDnsControlFake.take_calls()
  end

  test "creates an enabled supported provider mirror without scheduling a sync" do
    ServerDnsControlFake.configure(%{
      views: [{"default", self(), 0}],
      providers: {:ok, [%{name: "cf-main", type: :cloudflare, enabled: true}]}
    })

    payload = %{
      zone_payload()
      | "zone_name" => "Example.Test.",
        "provider_id" => "cf-main"
    }

    assert {:ok, result} = Dns.dispatch("server.dns.zones.create", payload)
    assert_valid_result("server.dns.zones.create", result)

    assert result["resource"] == %{
             zone_payload()
             | "provider_id" => "cf-main"
           }

    assert [
             {:view_manager, :list_control_views, []},
             {:zone_store, :get_zone, ["default", "example.test"]},
             {:provider_store, :get_config, ["cf-main"]},
             {:zone_store, :default_soa, ["example.test"]},
             {:zone_store, :create_zone,
              [
                "default",
                "example.test",
                _soa,
                [
                  cloud_mirror: %{
                    enabled: true,
                    connector_name: "cf-main",
                    provider: :cloudflare,
                    zone_id: "",
                    direction: :pull_from_cloud,
                    conflict_strategy: :cloud_wins
                  }
                ]
              ]},
             {:zone_controller, :start_zone, [:auth, "example.test", [view_name: "default"]]}
           ] = ServerDnsControlFake.take_calls()
  end

  test "accepts a cloud-zone sync without reporting completed record changes" do
    zone =
      Map.put(authoritative_zone(), :cloud_mirror, %{
        enabled: true,
        connector_name: "cf-main",
        provider: :cloudflare
      })

    ServerDnsControlFake.configure(%{
      zone_metadata: %{{"default", "example.test"} => zone}
    })

    assert {:ok, result} =
             Dns.dispatch("server.dns.zones.sync", %{
               "view_name" => "default",
               "zone_name" => "Example.Test.",
               "provider_id" => "cf-main"
             })

    assert result["view_name"] == "default"
    assert result["zone_name"] == "example.test"
    assert result["changed_records"] == 0
    assert_valid_result("server.dns.zones.sync", result)

    expected_resource = %{
      "view_name" => "default",
      "zone_name" => "example.test",
      "zone_type" => "authoritative",
      "provider_id" => "cf-main"
    }

    assert {:ok, expected_revision} = Revision.calculate(expected_resource)
    assert result["revision"] == expected_revision

    assert [
             {:tasks, :enqueue_cloud_zone_sync, ["default", "example.test", "cf-main"]},
             {:zone_store, :get_zone, ["default", "example.test"]}
           ] = ServerDnsControlFake.take_calls()
  end

  test "maps cloud-zone enqueue failures to stable Sync errors" do
    for {owner_result, code, message} <- [
          {{:error, :invalid}, :invalid, "invalid value"},
          {{:error, :not_found}, :not_found, "resource not found"},
          {{:error, :conflict}, :conflict, "operation conflict"},
          {{:error, :unsupported}, :unsupported, "unsupported operation"},
          {{:error, :apply_failed}, :apply_failed, "apply failed"},
          {{:error, :rollback_failed}, :rollback_failed, "rollback failed"},
          {{:error, {:owner_failed, "credential-token"}}, :apply_failed, "apply failed"}
        ] do
      ServerDnsControlFake.configure(%{responses: %{enqueue_cloud_zone_sync: [owner_result]}})

      assert {:error, %Error{code: ^code, message: ^message, details: %{}} = error} =
               Dns.dispatch("server.dns.zones.sync", %{
                 "view_name" => "default",
                 "zone_name" => "example.test",
                 "provider_id" => "cf-main"
               })

      refute inspect(error) =~ "credential-token"

      assert [
               {:tasks, :enqueue_cloud_zone_sync, ["default", "example.test", "cf-main"]}
             ] = ServerDnsControlFake.take_calls()
    end
  end

  test "creates each fixed RR type with its exact Store encoding" do
    ServerDnsControlFake.configure(%{
      zone_metadata: %{{"default", "example.test"} => authoritative_zone()}
    })

    for {type, store_type, values, expected_rrset} <- record_encodings() do
      owner = if type == "SRV", do: "_sip._tcp", else: "www"

      payload = %{
        record_payload(type, values)
        | "name" => owner,
          "record_id" => record_id(owner, type)
      }

      result = Dns.dispatch("server.dns.records.create", payload)
      assert match?({:ok, _result}, result), "type=#{type} result=#{inspect(result)}"
      {:ok, result} = result
      assert_valid_result("server.dns.records.create", result)

      assert [
               {:zone_store, :get_zone, ["default", "example.test"]},
               {:zone_store, :get_rrset, ["default", "example.test", ^owner, ^store_type]},
               {:zone_store, :put_rrset,
                ["default", "example.test", ^owner, ^store_type, ^expected_rrset]},
               {:zone_controller, :reload_zone, ["default", :auth, "example.test", []]}
             ] = ServerDnsControlFake.take_calls()
    end
  end

  test "restores an RRset and reloads restored state when activation fails" do
    original = [%{rdata: {192, 0, 2, 10}, ttl: 60}]

    ServerDnsControlFake.configure(%{
      zone_metadata: %{{"default", "example.test"} => authoritative_zone()},
      record_state: %{{"default", "example.test"} => [%{owner: "www", type: :a, rrset: original}]},
      responses: %{reload_zone: [{:error, :reload_failed}, :ok]}
    })

    assert {:error, %Error{code: :apply_failed}} =
             Dns.dispatch("server.dns.records.update", %{
               record_payload("A", ["192.0.2.11"])
               | "zone_name" => "Example.Test."
             })

    assert [
             {:zone_store, :get_zone, ["default", "example.test"]},
             {:zone_store, :get_rrset, ["default", "example.test", "www", :a]},
             {:zone_store, :put_rrset,
              ["default", "example.test", "www", :a, [%{rdata: {192, 0, 2, 11}, ttl: 60}]]},
             {:zone_controller, :reload_zone, ["default", :auth, "example.test", []]},
             {:zone_store, :put_rrset, ["default", "example.test", "www", :a, ^original]},
             {:zone_controller, :reload_zone, ["default", :auth, "example.test", []]}
           ] = ServerDnsControlFake.take_calls()

    assert ServerDnsControlFake.snapshot().record_state[{"default", "example.test"}] == [
             %{owner: "www", type: :a, rrset: original}
           ]

    assert ServerDnsControlFake.snapshot().serial_advances == 2
  end

  test "compensates a failed authoritative zone start and reports rollback failure precisely" do
    ServerDnsControlFake.configure(%{
      views: [{"default", self(), 0}],
      responses: %{start_zone: [{:error, :start_failed}]}
    })

    assert {:error, %Error{code: :apply_failed}} =
             Dns.dispatch("server.dns.zones.create", %{
               zone_payload()
               | "zone_name" => "Example.Test."
             })

    assert [
             {:view_manager, :list_control_views, []},
             {:zone_store, :get_zone, ["default", "example.test"]},
             {:zone_store, :default_soa, ["example.test"]},
             {:zone_store, :create_zone, ["default", "example.test", _soa, []]},
             {:zone_controller, :start_zone, [:auth, "example.test", [view_name: "default"]]},
             {:zone_controller, :stop_zone, ["default", :auth, "example.test"]},
             {:zone_store, :delete_zone, ["default", "example.test"]},
             {:zone_store, :get_zone, ["default", "example.test"]}
           ] = ServerDnsControlFake.take_calls()

    assert %{} == ServerDnsControlFake.snapshot().zone_metadata

    ServerDnsControlFake.configure(%{
      views: [{"default", self(), 0}],
      responses: %{start_zone: [{:error, :start_failed}], delete_zone: [{:error, :delete_failed}]}
    })

    assert {:error, %Error{code: :rollback_failed}} =
             Dns.dispatch("server.dns.zones.create", %{
               zone_payload()
               | "zone_name" => "Other.Test."
             })
  end

  test "zone create canonicalizes identity before checking for conflicts" do
    zone = authoritative_zone()

    ServerDnsControlFake.configure(%{
      views: [{"default", self(), 0}],
      zone_metadata: %{{"default", "example.test"} => zone}
    })

    before = mutation_state()
    payload = %{zone_payload() | "zone_name" => "Example.Test."}

    assert {:error, %Error{code: :conflict}} =
             Dns.dispatch("server.dns.zones.create", payload)

    assert [
             {:view_manager, :list_control_views, []},
             {:zone_store, :get_zone, ["default", "example.test"]}
           ] = ServerDnsControlFake.take_calls()

    assert mutation_state() == before

    assert Map.keys(ServerDnsControlFake.snapshot().zone_metadata) == [
             {"default", "example.test"}
           ]
  end

  test "invalid, empty, and root zone names fail before canonicalization side effects" do
    for zone_name <- ["", ".", "example..test"] do
      assert {:error, %Error{code: :invalid}} =
               Dns.dispatch("server.dns.zones.create", %{
                 zone_payload()
                 | "zone_name" => zone_name
               })

      assert [] = ServerDnsControlFake.take_calls()
    end
  end

  test "rejects immutable zone types and restores zone metadata after reload failure" do
    forward = %{view_name: "default", origin: "example.test", zone_type: :forward}
    ServerDnsControlFake.configure(%{zone_metadata: %{{"default", "example.test"} => forward}})

    assert {:error, %Error{code: :conflict}} =
             Dns.dispatch("server.dns.zones.update", zone_payload())

    assert [{:zone_store, :get_zone, ["default", "example.test"]}] =
             ServerDnsControlFake.take_calls()

    old = authoritative_zone()

    ServerDnsControlFake.configure(%{
      zone_metadata: %{{"default", "example.test"} => old},
      responses: %{reload_zone: [{:error, :reload_failed}, :ok]}
    })

    assert {:error, %Error{code: :apply_failed}} =
             Dns.dispatch("server.dns.zones.update", %{
               zone_payload()
               | "zone_name" => "Example.Test."
             })

    restored = ServerDnsControlFake.snapshot().zone_metadata[{"default", "example.test"}]
    assert Map.take(restored, Map.keys(old)) == old

    assert [
             {:zone_store, :get_zone, ["default", "example.test"]},
             {:zone_store, :update_zone, ["default", "example.test", %{cloud_mirror: nil}]},
             {:zone_controller, :reload_zone, ["default", :auth, "example.test", []]},
             {:zone_store, :update_zone, ["default", "example.test", ^old]},
             {:zone_controller, :reload_zone, ["default", :auth, "example.test", []]}
           ] = ServerDnsControlFake.take_calls()
  end

  test "restores deleted zone records and restarts after a stop failure" do
    records = [%{owner: "www", type: :a, rrset: [%{rdata: {192, 0, 2, 10}, ttl: 60}]}]

    zone =
      Map.merge(authoritative_zone(), %{
        default_ttl: 120,
        allow_dynamic_update: true,
        serial_strategy: :increment
      })

    ServerDnsControlFake.configure(%{
      zone_metadata: %{{"default", "example.test"} => zone},
      record_state: %{{"default", "example.test"} => records},
      responses: %{stop_zone: [{:error, :stop_failed}]}
    })

    assert {:error, %Error{code: :apply_failed}} =
             Dns.dispatch("server.dns.zones.delete", %{
               "view_name" => "default",
               "zone_name" => "Example.Test."
             })

    snapshot = ServerDnsControlFake.snapshot()

    assert [%{owner: "www", type: :a, rrset: [%{rdata: {192, 0, 2, 10}, ttl: 60}]}] =
             snapshot.record_state[{"default", "example.test"}]

    assert snapshot.zone_metadata[{"default", "example.test"}].soa.serial == 10
    assert snapshot.zone_metadata[{"default", "example.test"}].default_ttl == 120
    assert snapshot.zone_metadata[{"default", "example.test"}].allow_dynamic_update
    assert snapshot.zone_metadata[{"default", "example.test"}].serial_strategy == :increment

    assert [
             {:zone_store, :get_zone, ["default", "example.test"]},
             {:zone_store, :list_records, ["default", "example.test"]},
             {:zone_store, :delete_zone, ["default", "example.test"]},
             {:zone_controller, :stop_zone, ["default", :auth, "example.test"]},
             {:zone_store, :create_zone,
              [
                "default",
                "example.test",
                %{serial: 10},
                [
                  default_ttl: 120,
                  authoritative: true,
                  allow_dynamic_update: true,
                  serial_strategy: :increment
                ]
              ]},
             {:zone_store, :put_rrset,
              [
                "default",
                "example.test",
                "www",
                :a,
                [%{rdata: {192, 0, 2, 10}, ttl: 60}]
              ]},
             {:zone_controller, :start_zone, [:auth, "example.test", [view_name: "default"]]}
           ] = ServerDnsControlFake.take_calls()
  end

  test "record mutations reject missing and non-authoritative zones, stale IDs, and Store failures" do
    assert {:error, %Error{code: :not_found}} =
             Dns.dispatch("server.dns.records.create", record_payload("A", ["192.0.2.10"]))

    ServerDnsControlFake.configure(%{
      zone_metadata: %{
        {"default", "example.test"} => %{authoritative_zone() | zone_type: :forward}
      }
    })

    assert {:error, %Error{code: :unsupported}} =
             Dns.dispatch("server.dns.records.create", record_payload("A", ["192.0.2.10"]))

    ServerDnsControlFake.configure(%{
      zone_metadata: %{{"default", "example.test"} => authoritative_zone()},
      responses: %{put_rrset: [{:error, :store_failed}]}
    })

    stale = %{record_payload("A", ["192.0.2.10"]) | "record_id" => record_id("other", "A")}
    assert {:error, %Error{code: :invalid}} = Dns.dispatch("server.dns.records.create", stale)

    assert {:error, %Error{code: :apply_failed}} =
             Dns.dispatch("server.dns.records.create", record_payload("A", ["192.0.2.10"]))
  end

  test "record create canonicalizes its Store lookup and cannot replace an alias" do
    original = %{owner: "www", type: :a, rrset: [%{rdata: {192, 0, 2, 10}, ttl: 60}]}

    ServerDnsControlFake.configure(%{
      zone_metadata: %{{"default", "example.test"} => authoritative_zone()},
      record_state: %{{"default", "example.test"} => [original]},
      serial_advances: 0
    })

    before = mutation_state()

    payload = %{
      record_payload("A", ["192.0.2.11"])
      | "zone_name" => "Example.Test.",
        "name" => "WWW.",
        "record_id" => record_id("www", "A")
    }

    assert {:error, %Error{code: :conflict}} =
             Dns.dispatch("server.dns.records.create", payload)

    assert [
             {:zone_store, :get_zone, ["default", "example.test"]},
             {:zone_store, :get_rrset, ["default", "example.test", "www", :a]}
           ] = ServerDnsControlFake.take_calls()

    assert mutation_state() == before
  end

  test "zone persistence failures do not enter lifecycle or compensation phases" do
    records = [%{owner: "www", type: :a, rrset: [%{rdata: {192, 0, 2, 10}, ttl: 60}]}]

    ServerDnsControlFake.configure(%{
      views: [{"default", self(), 0}],
      zone_metadata: %{},
      record_state: %{},
      serial_advances: 0,
      responses: %{create_zone: [{:error, :store_failed}]}
    })

    before = mutation_state()

    assert {:error, %Error{code: :apply_failed}} =
             Dns.dispatch("server.dns.zones.create", %{
               zone_payload()
               | "zone_name" => "Example.Test."
             })

    assert [
             {:view_manager, :list_control_views, []},
             {:zone_store, :get_zone, ["default", "example.test"]},
             {:zone_store, :default_soa, ["example.test"]},
             {:zone_store, :create_zone, ["default", "example.test", _soa, []]}
           ] = ServerDnsControlFake.take_calls()

    assert mutation_state() == before

    ServerDnsControlFake.configure(%{
      views: [],
      zone_metadata: %{{"default", "example.test"} => authoritative_zone()},
      record_state: %{{"default", "example.test"} => records},
      serial_advances: 0,
      responses: %{update_zone: [{:error, :store_failed}]}
    })

    before = mutation_state()

    assert {:error, %Error{code: :apply_failed}} =
             Dns.dispatch("server.dns.zones.update", %{
               zone_payload()
               | "zone_name" => "Example.Test."
             })

    assert [
             {:zone_store, :get_zone, ["default", "example.test"]},
             {:zone_store, :update_zone, ["default", "example.test", %{cloud_mirror: nil}]}
           ] = ServerDnsControlFake.take_calls()

    assert mutation_state() == before

    ServerDnsControlFake.configure(%{
      zone_metadata: %{{"default", "example.test"} => authoritative_zone()},
      record_state: %{{"default", "example.test"} => records},
      serial_advances: 0,
      responses: %{delete_zone: [{:error, :store_failed}]}
    })

    before = mutation_state()

    assert {:error, %Error{code: :apply_failed}} =
             Dns.dispatch("server.dns.zones.delete", %{
               "view_name" => "default",
               "zone_name" => "Example.Test."
             })

    assert [
             {:zone_store, :get_zone, ["default", "example.test"]},
             {:zone_store, :list_records, ["default", "example.test"]},
             {:zone_store, :delete_zone, ["default", "example.test"]}
           ] = ServerDnsControlFake.take_calls()

    assert mutation_state() == before
  end

  test "record persistence failures do not enter lifecycle or compensation phases" do
    original = %{owner: "www", type: :a, rrset: [%{rdata: {192, 0, 2, 10}, ttl: 60}]}

    for {operation, payload, records, response, expected_calls} <- [
          {
            "server.dns.records.create",
            %{record_payload("A", ["192.0.2.11"]) | "zone_name" => "Example.Test."},
            [],
            :put_rrset,
            [
              {:zone_store, :get_zone, ["default", "example.test"]},
              {:zone_store, :get_rrset, ["default", "example.test", "www", :a]},
              {:zone_store, :put_rrset,
               [
                 "default",
                 "example.test",
                 "www",
                 :a,
                 [%{rdata: {192, 0, 2, 11}, ttl: 60}]
               ]}
            ]
          },
          {
            "server.dns.records.update",
            %{record_payload("A", ["192.0.2.11"]) | "zone_name" => "Example.Test."},
            [original],
            :put_rrset,
            [
              {:zone_store, :get_zone, ["default", "example.test"]},
              {:zone_store, :get_rrset, ["default", "example.test", "www", :a]},
              {:zone_store, :put_rrset,
               [
                 "default",
                 "example.test",
                 "www",
                 :a,
                 [%{rdata: {192, 0, 2, 11}, ttl: 60}]
               ]}
            ]
          },
          {
            "server.dns.records.delete",
            %{
              "view_name" => "default",
              "zone_name" => "Example.Test.",
              "record_id" => record_id("www", "A")
            },
            [original],
            :delete_rrset,
            [
              {:zone_store, :get_zone, ["default", "example.test"]},
              {:zone_store, :list_records, ["default", "example.test"]},
              {:zone_store, :get_rrset, ["default", "example.test", "www", :a]},
              {:zone_store, :delete_rrset, ["default", "example.test", "www", :a]}
            ]
          }
        ] do
      ServerDnsControlFake.configure(%{
        zone_metadata: %{{"default", "example.test"} => authoritative_zone()},
        record_state: %{{"default", "example.test"} => records},
        serial_advances: 0,
        responses: %{response => [{:error, :store_failed}]}
      })

      before = mutation_state()

      assert {:error, %Error{code: :apply_failed}} = Dns.dispatch(operation, payload)
      assert ServerDnsControlFake.take_calls() == expected_calls
      assert mutation_state() == before
      assert mutation_state().serial_advances == 0
      assert mutation_state().zone_metadata[{"default", "example.test"}].soa.serial == 10
    end
  end

  test "failed initial record persistence cannot advance the real Store SOA serial" do
    if Process.whereis(YellowDog.Store.TaskSupervisor) == nil do
      start_supervised!({Task.Supervisor, name: YellowDog.Store.TaskSupervisor})
    end

    previous_backend = Backend.active()
    EtsBackend.create_table()
    Backend.set_active(EtsBackend)

    zone_name = "serial-failure-#{System.unique_integer([:positive])}.example"
    soa = StoreZone.default_soa(zone_name) |> Map.put(:serial, 100)

    assert :ok =
             StoreZone.create_zone("default", zone_name, soa, serial_strategy: :increment)

    on_exit(fn ->
      if :ets.whereis(EtsBackend.table()) != :undefined do
        EtsBackend.delete(YellowDog.Store.Key.zone("default", zone_name))
      end

      Backend.set_active(previous_backend)
    end)

    dns_config = Application.fetch_env!(:yellow_dog, Dns)

    Application.put_env(
      :yellow_dog,
      Dns,
      Keyword.put(dns_config, :zone_store, ServerDnsControlFake.RealStoreFailingPut)
    )

    payload = %{
      record_payload("A", ["192.0.2.11"])
      | "zone_name" => zone_name
    }

    assert {:error, %Error{code: :apply_failed}} =
             Dns.dispatch("server.dns.records.create", payload)

    assert [
             {:zone_store, :put_rrset,
              [
                "default",
                ^zone_name,
                "www",
                :a,
                [%{rdata: {192, 0, 2, 11}, ttl: 60}]
              ]}
           ] = ServerDnsControlFake.take_calls()

    assert {:ok, %{soa: %{serial: 100}}} = StoreZone.get_zone("default", zone_name)
    assert {:error, :not_found} = StoreZone.get_rrset("default", zone_name, "www", :a)
  end

  describe "Dispatcher DNS mutation paths" do
    test "dispatches zone create against the current missing revision" do
      ServerDnsControlFake.configure(%{
        views: [{"default", self(), 0}],
        zones: %{"default" => {:ok, []}},
        zone_metadata: %{}
      })

      payload = %{zone_payload() | "zone_name" => "Example.Test."}

      assert {:ok, result} = dispatch_with_current_revision("server.dns.zones.create", payload)
      assert result["resource"] == zone_payload()
      assert_valid_result("server.dns.zones.create", result)

      assert [
               {:zone_store, :list_zones_for_view, ["default"]},
               {:view_manager, :list_control_views, []},
               {:zone_store, :get_zone, ["default", "example.test"]},
               {:zone_store, :default_soa, ["example.test"]},
               {:zone_store, :create_zone, ["default", "example.test", _soa, []]},
               {:zone_controller, :start_zone, [:auth, "example.test", [view_name: "default"]]}
             ] = ServerDnsControlFake.take_calls()

      assert_dispatcher_dns_dependencies()
    end

    test "dispatches zone update with its current revision" do
      zone = authoritative_zone()

      ServerDnsControlFake.configure(%{
        zones: %{"default" => {:ok, [zone]}},
        zone_metadata: %{{"default", "example.test"} => zone}
      })

      payload = %{zone_payload() | "zone_name" => "Example.Test."}

      assert {:ok, result} = dispatch_with_current_revision("server.dns.zones.update", payload)
      assert result["resource"] == zone_payload()
      assert_valid_result("server.dns.zones.update", result)

      assert [
               {:zone_store, :list_zones_for_view, ["default"]},
               {:zone_store, :get_zone, ["default", "example.test"]},
               {:zone_store, :update_zone, ["default", "example.test", %{cloud_mirror: nil}]},
               {:zone_controller, :reload_zone, ["default", :auth, "example.test", []]}
             ] = ServerDnsControlFake.take_calls()

      assert_dispatcher_dns_dependencies()
    end

    test "dispatches zone delete with its current revision" do
      zone = authoritative_zone()

      ServerDnsControlFake.configure(%{
        zones: %{"default" => {:ok, [zone]}},
        zone_metadata: %{{"default", "example.test"} => zone},
        record_state: %{{"default", "example.test"} => []}
      })

      payload = %{"view_name" => "default", "zone_name" => "Example.Test."}

      assert {:ok, result} = dispatch_with_current_revision("server.dns.zones.delete", payload)

      assert result["resource_ref"] == %{
               "view_name" => "default",
               "zone_name" => "example.test"
             }

      assert result["resource_type"] == "dns_zone"

      assert_valid_result("server.dns.zones.delete", result)

      assert [
               {:zone_store, :list_zones_for_view, ["default"]},
               {:zone_store, :get_zone, ["default", "example.test"]},
               {:zone_store, :list_records, ["default", "example.test"]},
               {:zone_store, :delete_zone, ["default", "example.test"]},
               {:zone_controller, :stop_zone, ["default", :auth, "example.test"]}
             ] = ServerDnsControlFake.take_calls()

      assert_dispatcher_dns_dependencies()
    end

    test "matching current revision cannot turn alias record create into update" do
      original = %{owner: "www", type: :a, rrset: [%{rdata: {192, 0, 2, 10}, ttl: 60}]}

      ServerDnsControlFake.configure(%{
        zone_metadata: %{{"default", "example.test"} => authoritative_zone()},
        record_state: %{{"default", "example.test"} => [original]},
        serial_advances: 0
      })

      payload = %{
        record_payload("A", ["192.0.2.11"])
        | "zone_name" => "Example.Test.",
          "name" => "WWW.",
          "record_id" => record_id("www", "A")
      }

      before = mutation_state()

      assert {:error, %Error{code: :conflict}} =
               dispatch_with_current_revision("server.dns.records.create", payload)

      assert [
               {:zone_store, :list_records, ["default", "example.test"]},
               {:zone_store, :get_zone, ["default", "example.test"]},
               {:zone_store, :get_rrset, ["default", "example.test", "www", :a]}
             ] = ServerDnsControlFake.take_calls()

      assert mutation_state() == before
      assert_dispatcher_dns_dependencies()
    end

    test "dispatches alias record update with its canonical current revision" do
      original = %{owner: "www", type: :a, rrset: [%{rdata: {192, 0, 2, 10}, ttl: 60}]}

      ServerDnsControlFake.configure(%{
        zone_metadata: %{{"default", "example.test"} => authoritative_zone()},
        record_state: %{{"default", "example.test"} => [original]},
        serial_advances: 0
      })

      payload = %{
        record_payload("A", ["192.0.2.11"])
        | "zone_name" => "Example.Test.",
          "name" => "WWW.",
          "record_id" => record_id("www", "A")
      }

      assert {:ok, result} =
               dispatch_with_current_revision("server.dns.records.update", payload)

      assert result["resource"] == %{
               payload
               | "zone_name" => "example.test",
                 "name" => "www"
             }

      assert_valid_result("server.dns.records.update", result)

      assert [
               {:zone_store, :list_records, ["default", "example.test"]},
               {:zone_store, :get_zone, ["default", "example.test"]},
               {:zone_store, :get_rrset, ["default", "example.test", "www", :a]},
               {:zone_store, :put_rrset,
                [
                  "default",
                  "example.test",
                  "www",
                  :a,
                  [%{rdata: {192, 0, 2, 11}, ttl: 60}]
                ]},
               {:zone_controller, :reload_zone, ["default", :auth, "example.test", []]}
             ] = ServerDnsControlFake.take_calls()

      assert mutation_state().serial_advances == 1
      assert_dispatcher_dns_dependencies()
    end

    test "dispatches record delete with its canonical current revision" do
      original = %{owner: "www", type: :a, rrset: [%{rdata: {192, 0, 2, 10}, ttl: 60}]}

      ServerDnsControlFake.configure(%{
        zone_metadata: %{{"default", "example.test"} => authoritative_zone()},
        record_state: %{{"default", "example.test"} => [original]},
        serial_advances: 0
      })

      payload = %{
        "view_name" => "default",
        "zone_name" => "Example.Test.",
        "record_id" => record_id("www", "A")
      }

      assert {:ok, result} =
               dispatch_with_current_revision("server.dns.records.delete", payload)

      assert result["resource_ref"] == %{
               "view_name" => "default",
               "zone_name" => "example.test",
               "record_id" => record_id("www", "A")
             }

      assert result["resource_type"] == "dns_record"

      assert_valid_result("server.dns.records.delete", result)

      assert [
               {:zone_store, :list_records, ["default", "example.test"]},
               {:zone_store, :get_zone, ["default", "example.test"]},
               {:zone_store, :list_records, ["default", "example.test"]},
               {:zone_store, :get_rrset, ["default", "example.test", "www", :a]},
               {:zone_store, :delete_rrset, ["default", "example.test", "www", :a]},
               {:zone_controller, :reload_zone, ["default", :auth, "example.test", []]}
             ] = ServerDnsControlFake.take_calls()

      assert mutation_state().record_state[{"default", "example.test"}] == []
      assert mutation_state().serial_advances == 1
      assert_dispatcher_dns_dependencies()
    end

    test "matching current revision cannot create a noncanonical alias zone" do
      zone = authoritative_zone()

      ServerDnsControlFake.configure(%{
        views: [{"default", self(), 0}],
        zones: %{"default" => {:ok, [zone]}},
        zone_metadata: %{{"default", "example.test"} => zone}
      })

      payload = %{zone_payload() | "zone_name" => "Example.Test."}
      before = mutation_state()

      assert {:error, %Error{code: :conflict}} =
               dispatch_with_current_revision("server.dns.zones.create", payload)

      assert [
               {:zone_store, :list_zones_for_view, ["default"]},
               {:view_manager, :list_control_views, []},
               {:zone_store, :get_zone, ["default", "example.test"]}
             ] = ServerDnsControlFake.take_calls()

      assert mutation_state() == before

      assert Map.keys(ServerDnsControlFake.snapshot().zone_metadata) == [
               {"default", "example.test"}
             ]

      assert_dispatcher_dns_dependencies()
    end
  end

  test "returns rollback_failed when restored RRsets cannot be persisted" do
    ServerDnsControlFake.configure(%{
      zone_metadata: %{{"default", "example.test"} => authoritative_zone()},
      responses: %{
        reload_zone: [{:error, :reload_failed}],
        delete_rrset: [{:error, :delete_failed}]
      }
    })

    assert {:error, %Error{code: :rollback_failed}} =
             Dns.dispatch("server.dns.records.create", record_payload("A", ["192.0.2.10"]))

    assert ServerDnsControlFake.snapshot().record_state[{"default", "example.test"}] == [
             %{owner: "www", type: :a, rrset: [%{rdata: {192, 0, 2, 10}, ttl: 60}]}
           ]

    assert ServerDnsControlFake.snapshot().serial_advances == 1
  end

  test "projects authoritative and forward zones in deterministic order" do
    ServerDnsControlFake.configure(%{
      zones: %{
        "default" =>
          {:ok,
           [
             %{
               view_name: "default",
               origin: "Forward.Example.",
               zone_type: :forward,
               forwarders: [%{address: "192.0.2.53", port: 53}],
               config_path: "/etc/yellowdog/zones.toml"
             },
             %{
               view_name: "default",
               origin: "Example.Test.",
               zone_type: :auth,
               cloud_mirror: %{connector_name: "aws-main", secret: "do-not-leak"},
               manager_pid: self()
             },
             %{view_name: "default", origin: "root", zone_type: :root}
           ]}
      }
    })

    assert {:ok, result} =
             Dns.dispatch("server.dns.zones.list", %{"view_name" => "default"})

    assert result["items"] == [
             %{
               "view_name" => "default",
               "zone_name" => "example.test",
               "zone_type" => "authoritative",
               "provider_id" => "aws-main"
             },
             %{
               "view_name" => "default",
               "zone_name" => "forward.example",
               "zone_type" => "forward",
               "provider_id" => nil
             }
           ]

    assert_valid_result("server.dns.zones.list", result)
    refute inspect(result) =~ "do-not-leak"
    refute inspect(result) =~ "/etc/yellowdog"
    refute inspect(result) =~ inspect(self())
  end

  test "projects RRsets with canonical owners, fixed types, values, and stable IDs" do
    expected_id = record_id("www.example.test", "A")

    ServerDnsControlFake.configure(%{
      records: %{
        {"default", "example.test"} =>
          {:ok,
           [
             %{
               owner: "WWW.Example.Test.",
               type: :a,
               rrset: [
                 %{rdata: %{address: "192.0.2.10", ttl: 300}},
                 %{rdata: {192, 0, 2, 11}, ttl: 300}
               ],
               store_module: YellowDog.Store.Zone,
               table: :dns_records,
               path: "/var/lib/yellowdog/records"
             },
             %{owner: "ignored", type: :caa, rrset: [%{rdata: "0 issue ca.example"}]}
           ]}
      }
    })

    assert {:ok, result} =
             Dns.dispatch("server.dns.records.list", %{
               "view_name" => "default",
               "zone_name" => "example.test"
             })

    assert result["items"] == [
             %{
               "view_name" => "default",
               "zone_name" => "example.test",
               "record_id" => expected_id,
               "name" => "www.example.test",
               "type" => "A",
               "ttl" => 300,
               "values" => ["192.0.2.10", "192.0.2.11"]
             }
           ]

    assert_valid_result("server.dns.records.list", result)
    refute inspect(result) =~ "YellowDog.Store"
    refute inspect(result) =~ "dns_records"
    refute inspect(result) =~ "/var/lib/yellowdog"
  end

  test "projects only the eight fixed Store RR types without atom conversion" do
    records = [
      %{owner: "a.example", type: :a, rrset: [%{rdata: {192, 0, 2, 1}, ttl: 120}]},
      %{
        owner: "aaaa.example",
        type: :aaaa,
        rrset: [%{rdata: {8193, 3512, 0, 0, 0, 0, 0, 1}, ttl: 120}]
      },
      %{
        owner: "alias.example",
        type: :cname,
        rrset: [%{rdata: "Target.Example.", ttl: 120}]
      },
      %{
        owner: "example",
        type: :mx,
        rrset: [%{rdata: "Mail.Example.", priority: 10, ttl: 120}]
      },
      %{owner: "example", type: :ns, rrset: [%{rdata: "NS1.Example.", ttl: 120}]},
      %{owner: "1.2.0.192.in-addr.arpa", type: :ptr, rrset: [%{rdata: "Ptr.Example.", ttl: 120}]},
      %{
        owner: "_sip._tcp.example",
        type: :srv,
        rrset: [%{rdata: {0, 5, 5060, "Sip.Example."}, ttl: 120}]
      },
      %{owner: "txt.example", type: :txt, rrset: [%{rdata: ["part", "two"], ttl: 120}]},
      %{owner: "ignored.example", type: :soa, rrset: [%{rdata: "internal", ttl: 120}]}
    ]

    ServerDnsControlFake.configure(%{
      records: %{{"default", "example"} => {:ok, records}}
    })

    assert {:ok, result} =
             Dns.dispatch("server.dns.records.list", %{
               "view_name" => "default",
               "zone_name" => "example"
             })

    by_type = Map.new(result["items"], &{&1["type"], &1["values"]})

    assert by_type == %{
             "A" => ["192.0.2.1"],
             "AAAA" => ["2001:db8::1"],
             "CNAME" => ["target.example"],
             "MX" => ["10 mail.example"],
             "NS" => ["ns1.example"],
             "PTR" => ["ptr.example"],
             "SRV" => ["0 5 5060 sip.example"],
             "TXT" => ["parttwo"]
           }

    assert_valid_result("server.dns.records.list", result)
  end

  test "projects ACLs and providers while removing unsupported and secret fields" do
    ServerDnsControlFake.configure(%{
      acls: [
        %{
          name: "blocked",
          rules: [%{action: "deny", network: "203.0.113.0/24"}],
          source_path: "/etc/yellowdog/acls.toml",
          owner_pid: self()
        },
        %{name: "trusted", rules: [%{action: :allow, network: "10.0.0.0/8"}]}
      ],
      providers:
        {:ok,
         [
           %{
             name: "legacy-aws",
             type: :aws,
             credentials: %{access_key_id: "AKIA-SECRET", secret_access_key: "secret"},
             adapter: YellowDog.DnsProvider.Provider.Aws,
             config_path: "/etc/yellowdog/providers.toml"
           },
           %{name: "cf-main", type: :cloudflare, credentials: %{api_token: "cf-secret"}},
           %{name: "gcp-hidden", type: :gcp, credentials: %{token: "hidden"}}
         ]}
    })

    assert {:ok, acl_result} = Dns.dispatch("server.dns.acls.list", %{})
    assert {:ok, provider_result} = Dns.dispatch("server.dns.providers.list", %{})

    assert acl_result["items"] == [
             %{
               "acl_id" => "blocked",
               "networks" => ["203.0.113.0/24"],
               "action" => "deny"
             },
             %{"acl_id" => "trusted", "networks" => ["10.0.0.0/8"], "action" => "allow"}
           ]

    assert provider_result["items"] == [
             %{
               "provider_id" => "cf-main",
               "provider_type" => "cloudflare",
               "endpoint" => nil,
               "credential_ref" => credential_ref("cf-main")
             },
             %{
               "provider_id" => "legacy-aws",
               "provider_type" => "route53",
               "endpoint" => nil,
               "credential_ref" => credential_ref("legacy-aws")
             }
           ]

    assert_valid_result("server.dns.acls.list", acl_result)
    assert_valid_result("server.dns.providers.list", provider_result)

    encoded = inspect({acl_result, provider_result})
    refute encoded =~ "SECRET"
    refute encoded =~ "cf-secret"
    refute encoded =~ "DnsProvider.Provider"
    refute encoded =~ "/etc/yellowdog"
    refute encoded =~ inspect(self())
  end

  test "updates a legacy Route 53 provider without exposing or changing credentials" do
    provider = %{
      name: "legacy-aws",
      type: :aws,
      credentials: %{access_key_id: "AKIA-SECRET", secret_access_key: "secret"}
    }

    ServerDnsControlFake.configure(%{providers: {:ok, [provider]}})

    payload = %{
      "provider_id" => "legacy-aws",
      "provider_type" => "route53",
      "endpoint" => nil,
      "credential_ref" => credential_ref("legacy-aws")
    }

    assert {:ok, result} = Dns.dispatch("server.dns.providers.update", payload)
    assert_valid_result("server.dns.providers.update", result)
    assert result["resource"] == payload

    assert [
             {:provider_facade, :fetch_provider, ["legacy-aws"]},
             {:provider_facade, :update_provider, ["legacy-aws", %{}]}
           ] = ServerDnsControlFake.take_calls()

    assert {:ok, [stored]} = ServerDnsControlFake.snapshot().providers
    assert stored.type == :aws
    assert stored.credentials == provider.credentials
    refute inspect(result) =~ "SECRET"
    refute inspect(result) =~ "secret"
  end

  test "deletes a provider with the exact deleted resource result" do
    ServerDnsControlFake.configure(%{providers: {:ok, [%{name: "cf-main", type: :cloudflare}]}})

    assert {:ok, result} =
             Dns.dispatch("server.dns.providers.delete", %{"provider_id" => "cf-main"})

    assert_valid_result("server.dns.providers.delete", result)
    assert result["resource_type"] == "dns_provider"
    assert result["resource_id"] == "cf-main"
    assert result["resource_ref"] == %{"provider_id" => "cf-main"}
    assert [{:provider_facade, :remove_provider, ["cf-main"]}] = ServerDnsControlFake.take_calls()
  end

  test "rejects unsupported provider writes before facade calls" do
    external_ref = %{
      "provider_id" => "cf-main",
      "provider_type" => "cloudflare",
      "endpoint" => nil,
      "credential_ref" => "external-secret"
    }

    assert {:error, %Error{code: :unsupported}} =
             Dns.dispatch("server.dns.providers.create", %{
               external_ref
               | "credential_ref" => credential_ref("cf-main")
             })

    for payload <- [
          external_ref,
          %{external_ref | "endpoint" => "https://provider.example"},
          %{external_ref | "provider_type" => "rfc2136", "endpoint" => nil}
        ] do
      assert {:error, %Error{code: :unsupported}} =
               Dns.dispatch("server.dns.providers.update", payload)
    end

    assert [] = ServerDnsControlFake.take_calls()
  end

  test "maps non-lossy provider facade failures to bounded errors" do
    payload = %{
      "provider_id" => "cf-main",
      "provider_type" => "cloudflare",
      "endpoint" => nil,
      "credential_ref" => credential_ref("cf-main")
    }

    ServerDnsControlFake.configure(%{responses: %{fetch_provider: [{:error, :not_found}]}})

    assert {:error, %Error{code: :not_found}} =
             Dns.dispatch("server.dns.providers.update", payload)

    ServerDnsControlFake.configure(%{
      responses: %{fetch_provider: [{:error, :owner_unavailable}]}
    })

    assert {:error, %Error{code: :apply_failed}} =
             Dns.dispatch("server.dns.providers.update", payload)
  end

  test "preserves rollback_failed from provider update as a bounded Sync error" do
    provider = %{name: "cf-main", type: :cloudflare, credentials: %{api_token: "secret"}}
    payload = provider_payload("cf-main")

    ServerDnsControlFake.configure(%{
      providers: {:ok, [provider]},
      responses: %{update_provider: [{:error, :rollback_failed}]}
    })

    assert Dns.dispatch("server.dns.providers.update", payload) ==
             {:error, Error.new(:rollback_failed, "rollback failed", %{})}

    assert [
             {:provider_facade, :fetch_provider, ["cf-main"]},
             {:provider_facade, :update_provider, ["cf-main", %{}]}
           ] = ServerDnsControlFake.take_calls()
  end

  test "preserves rollback_failed from provider delete as a bounded Sync error" do
    ServerDnsControlFake.configure(%{
      responses: %{remove_provider: [{:error, :rollback_failed}]}
    })

    assert Dns.dispatch("server.dns.providers.delete", %{"provider_id" => "cf-main"}) ==
             {:error, Error.new(:rollback_failed, "rollback failed", %{})}

    assert [{:provider_facade, :remove_provider, ["cf-main"]}] =
             ServerDnsControlFake.take_calls()
  end

  test "sanitizes structured provider owner errors" do
    provider = %{name: "cf-main", type: :cloudflare, credentials: %{api_token: "secret"}}
    payload = provider_payload("cf-main")

    owner_error =
      Error.new(:rollback_failed, "owner credential materializer failed", %{
        "credential" => "owner-secret"
      })

    ServerDnsControlFake.configure(%{
      providers: {:ok, [provider]},
      responses: %{update_provider: [{:error, owner_error}]}
    })

    result = Dns.dispatch("server.dns.providers.update", payload)

    assert result == {:error, Error.new(:rollback_failed, "rollback failed", %{})}
    refute inspect(result) =~ "materializer"
    refute inspect(result) =~ "owner-secret"

    ServerDnsControlFake.configure(%{
      providers: {:ok, [provider]},
      responses: %{update_provider: [{:error, {:owner_failed, "credential-token"}}]}
    })

    result = Dns.dispatch("server.dns.providers.update", payload)

    assert result == {:error, Error.new(:apply_failed, "apply failed", %{})}
    refute inspect(result) =~ "owner_failed"
    refute inspect(result) =~ "credential-token"
  end

  test "Dispatcher rejects stale provider updates before the provider facade mutates" do
    provider = %{name: "cf-main", type: :cloudflare, credentials: %{api_token: "secret"}}

    payload = %{
      "provider_id" => "cf-main",
      "provider_type" => "cloudflare",
      "endpoint" => nil,
      "credential_ref" => credential_ref("cf-main")
    }

    ServerDnsControlFake.configure(%{providers: {:ok, [provider]}})

    assert {:ok, current} = Dns.current("server.dns.providers.update", payload)
    {:ok, current_revision} = Revision.calculate(current)
    ServerDnsControlFake.take_calls()
    {:ok, payload_digest} = Digest.calculate(payload)

    assert {:error, %Error{code: :conflict, message: "stale revision"}} =
             Dispatcher.dispatch(%Envelope{
               protocol_version: 1,
               request_id: @request_id,
               target_type: :server,
               target_id: "server-task-3d",
               operation: "server.dns.providers.update",
               idempotency_key: @idempotency_key,
               payload: payload,
               payload_digest: payload_digest,
               expected_revision: String.duplicate("0", 64),
               config_version: nil,
               sent_at: @sent_at
             })

    refute current_revision == String.duplicate("0", 64)
    assert [{:provider_facade, :fetch_provider, ["cf-main"]}] = ServerDnsControlFake.take_calls()
    assert_dispatcher_dns_dependencies()
  end

  test "rejects mixed-action and geo ACLs instead of projecting altered policies" do
    for acl <- [
          %{
            name: "mixed",
            rules: [
              %{action: "allow", network: "10.0.0.0/8"},
              %{action: "deny", network: "10.1.0.0/16"}
            ]
          },
          %{
            name: "geo",
            rules: [%{action: "allow", geo_countries: ["US", "CA"]}]
          }
        ] do
      ServerDnsControlFake.configure(%{acls: [acl]})

      assert {:error, %Error{code: :unsupported}} =
               Dns.dispatch("server.dns.acls.list", %{})

      assert {:error, %Error{code: :unsupported}} =
               Dns.current("server.dns.acls.update", %{"acl_id" => acl.name})
    end
  end

  test "canonicalizes rule and legacy ACL networks before revision and current snapshots" do
    rules_acl = %{
      name: "rules",
      rules: [
        %{action: "allow", network: "2001:0db8:0000:0000:0000:0000:0000:1234/32"},
        %{action: "allow", network: "10.1.2.3/8"},
        %{action: "allow", network: "10.0.0.0/8"}
      ]
    }

    legacy_acl = %{
      name: "legacy",
      action: :deny,
      networks: ["2001:0db8:0000:0000:0000:0000:0000:0001/48", "192.0.2.99/24"]
    }

    ServerDnsControlFake.configure(%{acls: [rules_acl, legacy_acl]})

    assert {:ok, first} = Dns.dispatch("server.dns.acls.list", %{})

    assert first["items"] == [
             %{
               "acl_id" => "legacy",
               "action" => "deny",
               "networks" => ["192.0.2.0/24", "2001:db8::/48"]
             },
             %{
               "acl_id" => "rules",
               "action" => "allow",
               "networks" => ["10.0.0.0/8", "2001:db8::/32"]
             }
           ]

    assert {:ok, Enum.at(first["items"], 0)} ==
             Dns.current("server.dns.acls.update", %{"acl_id" => "legacy"})

    assert {:ok, Enum.at(first["items"], 1)} ==
             Dns.current("server.dns.acls.update", %{"acl_id" => "rules"})

    ServerDnsControlFake.configure(%{
      acls: [
        %{legacy_acl | networks: Enum.reverse(legacy_acl.networks)},
        %{rules_acl | rules: Enum.reverse(rules_acl.rules)}
      ]
    })

    assert {:ok, reversed} = Dns.dispatch("server.dns.acls.list", %{})
    assert reversed["items"] == first["items"]
    assert reversed["revision"] == first["revision"]
    assert_valid_result("server.dns.acls.list", reversed)
  end

  test "projects query logs and metrics through their read facades" do
    ServerDnsControlFake.configure(%{
      logs: [
        %{
          id: "log-forwarded",
          qname: "WWW.Example.Test.",
          response_code: :noerror,
          resolution_type: :recursive,
          timestamp: ~U[2026-07-15 23:59:59Z],
          client_ip: {192, 0, 2, 20},
          error: "token=must-not-leak"
        },
        %{
          id: "log-refused",
          qname: "blocked.example.test",
          response_code: :refused,
          timestamp: ~U[2026-07-15 23:59:58Z]
        }
      ],
      metrics: %{
        counters: %{queries_total: 42, cache_hits: 7},
        responses_by_code: [noerror: 38, refused: 2, servfail: 2],
        table: :dns_metrics,
        started_at: ~U[2026-07-15 00:00:00Z]
      }
    })

    assert {:ok, log_result} =
             Dns.dispatch("server.dns.logs.list", %{
               "view_name" => "default",
               "limit" => 10
             })

    assert log_result["items"] == [
             %{
               "log_id" => "log-forwarded",
               "query_name" => "www.example.test",
               "action" => "forwarded",
               "occurred_at" => "2026-07-15T23:59:59Z"
             },
             %{
               "log_id" => "log-refused",
               "query_name" => "blocked.example.test",
               "action" => "refused",
               "occurred_at" => "2026-07-15T23:59:58Z"
             }
           ]

    assert {:ok, %{"queries" => 42, "failures" => 4} = metrics_result} =
             Dns.dispatch("server.dns.metrics.get", %{})

    assert_valid_result("server.dns.logs.list", log_result)
    assert_valid_result("server.dns.metrics.get", metrics_result)
    refute inspect(log_result) =~ "must-not-leak"

    assert {:query_logger, :control_snapshot, ["default"]} in ServerDnsControlFake.take_calls()
  end

  test "query-log revision is page-size independent and cursors reach older entries" do
    ServerDnsControlFake.configure(%{
      logs: [
        log_entry("log-c", "c.example", ~U[2026-07-16 00:00:03Z]),
        log_entry("log-a", "a.example", ~U[2026-07-16 00:00:01Z]),
        log_entry("log-b", "b.example", ~U[2026-07-16 00:00:02Z])
      ]
    })

    assert {:ok, one} =
             Dns.dispatch("server.dns.logs.list", %{"view_name" => "default", "limit" => 1})

    assert {:ok, two} =
             Dns.dispatch("server.dns.logs.list", %{"view_name" => "default", "limit" => 2})

    assert one["revision"] == two["revision"]
    assert Enum.map(one["items"], & &1["log_id"]) == ["log-a"]

    assert {:ok, older} =
             Dns.dispatch("server.dns.logs.list", %{
               "view_name" => "default",
               "cursor" => "log-a",
               "limit" => 2
             })

    assert Enum.map(older["items"], & &1["log_id"]) == ["log-b", "log-c"]
    assert older["revision"] == one["revision"]
  end

  test "every approved read returns an exact Operation.validate_result shape" do
    ServerDnsControlFake.configure(%{
      views: [{"default", self(), 0}],
      view_stats: %{views: %{"default" => %{recursion_enabled: false}}},
      zones: %{"default" => {:ok, []}},
      records: %{{"default", "example.test"} => {:ok, []}},
      acls: [],
      providers: {:ok, []},
      logs: [],
      metrics: %{counters: %{queries_total: 0}, responses_by_code: []}
    })

    payloads = %{
      "server.dns.views.list" => %{},
      "server.dns.zones.list" => %{"view_name" => "default"},
      "server.dns.records.list" => %{
        "view_name" => "default",
        "zone_name" => "example.test"
      },
      "server.dns.acls.list" => %{},
      "server.dns.providers.list" => %{},
      "server.dns.logs.list" => %{"view_name" => "default"},
      "server.dns.metrics.get" => %{}
    }

    for operation <- @read_operations do
      assert {:ok, result} = Dns.dispatch(operation, Map.fetch!(payloads, operation))
      assert_valid_result(operation, result)
    end
  end

  test "list results are bounded, cursor-aware, deterministic, and clock-testable" do
    views =
      for index <- 0..999 do
        {"view-#{index |> Integer.to_string() |> String.pad_leading(4, "0")}", self(), index}
      end

    ServerDnsControlFake.configure(%{views: Enum.reverse(views)})

    assert {:ok, first} = Dns.dispatch("server.dns.views.list", %{})
    assert length(first["items"]) == 1_000
    assert hd(first["items"])["view_name"] == "view-0000"
    assert List.last(first["items"])["view_name"] == "view-0999"

    assert {:ok, page} =
             Dns.dispatch("server.dns.views.list", %{"cursor" => "view-0002", "limit" => 2})

    assert Enum.map(page["items"], & &1["view_name"]) == ["view-0003", "view-0004"]
    assert page["revision"] == first["revision"]

    ServerDnsControlFake.configure(%{now: ~U[2026-07-16 12:34:56Z]})
    assert {:ok, later} = Dns.dispatch("server.dns.views.list", %{})
    assert later["observed_at"] == "2026-07-16T12:34:56Z"
    assert later["revision"] == first["revision"]
  end

  test "rejects oversized view owner results instead of truncating canonical resources" do
    views =
      for index <- 0..1_000 do
        %{
          name: "view-#{index |> Integer.to_string() |> String.pad_leading(4, "0")}",
          match_clients: [],
          recursion: false
        }
      end

    ServerDnsControlFake.configure(%{views: views})

    assert {:error, %Error{code: :unsupported, message: "unsupported operation", details: %{}}} =
             Dns.dispatch("server.dns.views.list", %{})

    assert {:error, %Error{code: :unsupported, message: "unsupported operation", details: %{}}} =
             Dns.current("server.dns.views.update", %{"view_name" => "view-0000"})
  end

  test "sorts RRset values and derives an order-independent equal TTL" do
    first = %{
      owner: "www",
      type: :a,
      rrset: [%{rdata: {192, 0, 2, 2}, ttl: 60}, %{rdata: {192, 0, 2, 1}, ttl: 60}]
    }

    second = %{first | rrset: Enum.reverse(first.rrset)}

    ServerDnsControlFake.configure(%{
      records: %{{"default", "example.test"} => {:ok, [first]}}
    })

    assert {:ok, unsorted} =
             Dns.dispatch("server.dns.records.list", %{
               "view_name" => "default",
               "zone_name" => "example.test"
             })

    ServerDnsControlFake.configure(%{
      records: %{{"default", "example.test"} => {:ok, [second]}}
    })

    assert {:ok, reversed} =
             Dns.dispatch("server.dns.records.list", %{
               "view_name" => "default",
               "zone_name" => "example.test"
             })

    assert hd(unsorted["items"])["values"] == ["192.0.2.1", "192.0.2.2"]
    assert hd(unsorted["items"])["ttl"] == 60
    assert unsorted["items"] == reversed["items"]
    assert unsorted["revision"] == reversed["revision"]
  end

  test "rejects unequal RRset TTLs in either entry order" do
    rrset = [%{rdata: {192, 0, 2, 1}, ttl: 60}, %{rdata: {192, 0, 2, 2}, ttl: 120}]

    for entries <- [rrset, Enum.reverse(rrset)] do
      ServerDnsControlFake.configure(%{
        records: %{
          {"default", "example.test"} => {:ok, [%{owner: "www", type: :a, rrset: entries}]}
        }
      })

      assert {:error, %Error{code: :invalid, message: "invalid value", details: %{}}} =
               Dns.dispatch("server.dns.records.list", %{
                 "view_name" => "default",
                 "zone_name" => "example.test"
               })
    end
  end

  test "rejects missing and partially specified RRset TTLs in either entry order" do
    partial = [%{rdata: {192, 0, 2, 1}, ttl: 60}, %{rdata: {192, 0, 2, 2}}]
    missing = [%{rdata: {192, 0, 2, 1}}, %{rdata: {192, 0, 2, 2}}]

    for entries <- [partial, Enum.reverse(partial), missing, Enum.reverse(missing)] do
      ServerDnsControlFake.configure(%{
        records: %{
          {"default", "example.test"} =>
            {:ok, [%{owner: "www", type: :a, ttl: 60, rrset: entries}]}
        }
      })

      assert {:error, %Error{code: :invalid}} =
               Dns.dispatch("server.dns.records.list", %{
                 "view_name" => "default",
                 "zone_name" => "example.test"
               })
    end
  end

  test "rejects invalid RRset TTL values" do
    for ttl <- [-1, 2_147_483_648, "60", nil] do
      ServerDnsControlFake.configure(%{
        records: %{
          {"default", "example.test"} =>
            {:ok, [%{owner: "www", type: :a, rrset: [%{rdata: {192, 0, 2, 1}, ttl: ttl}]}]}
        }
      })

      assert {:error, %Error{code: :invalid}} =
               Dns.dispatch("server.dns.records.list", %{
                 "view_name" => "default",
                 "zone_name" => "example.test"
               })
    end
  end

  test "rejects conflicting top-level and nested RRset TTLs in either entry order" do
    rrset = [
      %{ttl: 60, rdata: %{address: {192, 0, 2, 1}, ttl: 120}},
      %{ttl: 60, rdata: %{address: {192, 0, 2, 2}, ttl: 60}}
    ]

    for entries <- [rrset, Enum.reverse(rrset)] do
      ServerDnsControlFake.configure(%{
        records: %{
          {"default", "example.test"} => {:ok, [%{owner: "www", type: :a, rrset: entries}]}
        }
      })

      assert {:error, %Error{code: :invalid}} =
               Dns.dispatch("server.dns.records.list", %{
                 "view_name" => "default",
                 "zone_name" => "example.test"
               })
    end
  end

  test "rejects invalid nested RRset TTLs even when top-level TTLs are valid" do
    rrset = [
      %{ttl: 60, rdata: %{address: {192, 0, 2, 1}, ttl: "60"}},
      %{ttl: 60, rdata: %{address: {192, 0, 2, 2}, ttl: 60}}
    ]

    for entries <- [rrset, Enum.reverse(rrset)] do
      ServerDnsControlFake.configure(%{
        records: %{
          {"default", "example.test"} => {:ok, [%{owner: "www", type: :a, rrset: entries}]}
        }
      })

      assert {:error, %Error{code: :invalid}} =
               Dns.dispatch("server.dns.records.list", %{
                 "view_name" => "default",
                 "zone_name" => "example.test"
               })
    end
  end

  test "accepts consistent duplicate TTL locations with stable reversal" do
    rrset = [
      %{ttl: 60, rdata: %{address: {192, 0, 2, 2}, ttl: 60}},
      %{ttl: 60, rdata: %{address: {192, 0, 2, 1}, ttl: 60}}
    ]

    results =
      for entries <- [rrset, Enum.reverse(rrset)] do
        ServerDnsControlFake.configure(%{
          records: %{
            {"default", "example.test"} => {:ok, [%{owner: "www", type: :a, rrset: entries}]}
          }
        })

        assert {:ok, result} =
                 Dns.dispatch("server.dns.records.list", %{
                   "view_name" => "default",
                   "zone_name" => "example.test"
                 })

        result
      end

    assert [first, second] = results
    assert hd(first["items"])["ttl"] == 60
    assert first["items"] == second["items"]
    assert first["revision"] == second["revision"]
  end

  test "validates projected reads and current snapshots before returning ok" do
    ServerDnsControlFake.configure(%{
      views: [{"a-valid", self(), 0}, {"default", self(), 1}],
      view_stats: %{
        views: %{
          "a-valid" => %{match_clients: ["10.0.0.0/8"], recursion_enabled: false},
          "default" => %{match_clients: ["not-a-cidr"], recursion_enabled: false}
        }
      }
    })

    assert {:error, %Error{code: :invalid, message: "invalid value", details: %{}}} =
             Dns.dispatch("server.dns.views.list", %{"limit" => 1})

    assert {:error, %Error{code: :invalid, message: "invalid value", details: %{}}} =
             Dns.current("server.dns.views.update", %{"view_name" => "default"})
  end

  test "current snapshots use the same canonical view, zone, ACL, and provider resources" do
    expected_credential_ref = credential_ref("cf-main")

    ServerDnsControlFake.configure(%{
      views: [{"default", self(), 0}],
      view_stats: %{
        views: %{"default" => %{match_clients: ["0.0.0.0/0"], recursion_enabled: false}}
      },
      zones: %{
        "default" =>
          {:ok,
           [
             %{
               view_name: "default",
               origin: "example.test",
               zone_type: :auth,
               cloud_mirror: %{connector_name: "cf-main"}
             }
           ]}
      },
      acls: [%{name: "trusted", rules: [%{action: :allow, network: "10.0.0.0/8"}]}],
      providers: {:ok, [%{name: "cf-main", type: :cloudflare, credentials: %{token: "secret"}}]}
    })

    assert {:ok,
            %{
              "view_name" => "default",
              "match_clients" => ["0.0.0.0/0"],
              "recursion" => false
            }} = Dns.current("server.dns.views.update", %{"view_name" => "default"})

    assert {:ok,
            %{
              "view_name" => "default",
              "zone_name" => "example.test",
              "zone_type" => "authoritative",
              "provider_id" => "cf-main"
            }} =
             Dns.current("server.dns.zones.delete", %{
               "view_name" => "default",
               "zone_name" => "example.test"
             })

    assert {:ok, %{"acl_id" => "trusted", "networks" => ["10.0.0.0/8"], "action" => "allow"}} =
             Dns.current("server.dns.acls.update", %{"acl_id" => "trusted"})

    assert {:ok,
            %{
              "provider_id" => "cf-main",
              "provider_type" => "cloudflare",
              "endpoint" => nil,
              "credential_ref" => ^expected_credential_ref
            }} = Dns.current("server.dns.providers.delete", %{"provider_id" => "cf-main"})
  end

  test "current returns missing only for absent creates and not_found for update/delete" do
    ServerDnsControlFake.configure(%{
      views: [],
      zones: %{"default" => {:ok, []}},
      acls: [],
      providers: {:ok, []}
    })

    assert {:ok, :missing} =
             Dns.current("server.dns.views.create", %{"view_name" => "new-view"})

    assert {:ok, :missing} =
             Dns.current("server.dns.zones.create", %{
               "view_name" => "default",
               "zone_name" => "new.example"
             })

    assert {:ok, :missing} =
             Dns.current("server.dns.acls.create", %{"acl_id" => "new-acl"})

    assert {:ok, :missing} =
             Dns.current("server.dns.providers.create", %{"provider_id" => "new-provider"})

    for {operation, payload} <- [
          {"server.dns.views.update", %{"view_name" => "missing"}},
          {"server.dns.zones.delete",
           %{"view_name" => "default", "zone_name" => "missing.example"}},
          {"server.dns.acls.update", %{"acl_id" => "missing"}},
          {"server.dns.providers.delete", %{"provider_id" => "missing"}}
        ] do
      assert {:error, %Error{code: :not_found}} = Dns.current(operation, payload)
    end
  end

  test "record current snapshots are stable and scoped to the supplied view and zone" do
    id = record_id("www", "A")
    record = %{owner: "WWW.", type: :a, rrset: [%{rdata: {192, 0, 2, 10}, ttl: 60}]}

    ServerDnsControlFake.configure(%{
      records: %{
        {"default", "one.example"} => {:ok, [record]},
        {"default", "two.example"} => {:ok, [record]}
      }
    })

    assert {:ok, snapshot} =
             Dns.current("server.dns.records.update", %{
               "view_name" => "default",
               "zone_name" => "one.example",
               "record_id" => id,
               "name" => "www",
               "type" => "A"
             })

    assert snapshot == %{
             "view_name" => "default",
             "zone_name" => "one.example",
             "record_id" => id,
             "name" => "www",
             "type" => "A",
             "ttl" => 60,
             "values" => ["192.0.2.10"]
           }

    ServerDnsControlFake.take_calls()

    assert {:error, %Error{code: :not_found}} =
             Dns.current("server.dns.records.delete", %{
               "view_name" => "default",
               "zone_name" => "absent.example",
               "record_id" => id
             })

    assert [{:zone_store, :list_records, ["default", "absent.example"]}] =
             ServerDnsControlFake.take_calls()
  end

  test "record IDs reject malformed, missing, duplicate, and mismatched references" do
    id = record_id("www", "A")
    duplicate_a = %{owner: "WWW.", type: :a, rrset: [%{rdata: {192, 0, 2, 1}, ttl: 60}]}
    duplicate_b = %{owner: "www", type: :a, rrset: [%{rdata: {192, 0, 2, 2}, ttl: 60}]}

    ServerDnsControlFake.configure(%{
      records: %{
        {"default", "empty.example"} => {:ok, []},
        {"default", "duplicate.example"} => {:ok, [duplicate_a, duplicate_b]}
      }
    })

    assert {:error, %Error{code: :invalid}} =
             Dns.current("server.dns.records.delete", %{
               "view_name" => "default",
               "zone_name" => "empty.example",
               "record_id" => "rr-not-a-digest"
             })

    assert [] = ServerDnsControlFake.take_calls()

    assert {:error, %Error{code: :not_found}} =
             Dns.current("server.dns.records.delete", %{
               "view_name" => "default",
               "zone_name" => "empty.example",
               "record_id" => id
             })

    assert {:error, %Error{code: :conflict}} =
             Dns.current("server.dns.records.delete", %{
               "view_name" => "default",
               "zone_name" => "duplicate.example",
               "record_id" => id
             })

    assert {:error, %Error{code: :invalid}} =
             Dns.current("server.dns.records.create", %{
               "view_name" => "default",
               "zone_name" => "empty.example",
               "record_id" => id,
               "name" => "mail",
               "type" => "A"
             })
  end

  test "caller record types never create atoms" do
    payload = %{
      "view_name" => "default",
      "zone_name" => "example.test",
      "record_id" => String.duplicate("f", 64) |> then(&("rr-" <> &1)),
      "name" => "www",
      "type" => "UNREGISTERED-TYPE-WARMUP"
    }

    assert {:error, %Error{code: :invalid}} =
             Dns.current("server.dns.records.create", payload)

    initial_atom_count = :erlang.system_info(:atom_count)

    for index <- 1..100 do
      assert {:error, %Error{code: :invalid}} =
               Dns.current(
                 "server.dns.records.create",
                 %{payload | "type" => "UNREGISTERED-TYPE-#{index}"}
               )
    end

    assert :erlang.system_info(:atom_count) == initial_atom_count
    assert [] = ServerDnsControlFake.take_calls()
  end

  test "missing processes and unavailable stores return stable typed errors" do
    ServerDnsControlFake.configure(%{views: {:exit, :noproc}})

    assert {:error, %Error{code: :not_found, message: "resource not found", details: %{}}} =
             Dns.dispatch("server.dns.views.list", %{})

    ServerDnsControlFake.configure(%{zones: {:error, :backend_unavailable}})

    assert {:error, %Error{code: :apply_failed, message: "apply failed", details: %{}}} =
             Dns.dispatch("server.dns.zones.list", %{"view_name" => "default"})

    ServerDnsControlFake.configure(%{views: {:error, :control_snapshot_too_large}})

    assert {:error, %Error{code: :unsupported, message: "unsupported operation", details: %{}}} =
             Dns.dispatch("server.dns.views.list", %{})
  end

  test "mutation dispatch and unknown names are unsupported before dependency calls" do
    supported = [
      "server.dns.zones.create",
      "server.dns.zones.update",
      "server.dns.zones.delete",
      "server.dns.zones.sync",
      "server.dns.records.create",
      "server.dns.records.update",
      "server.dns.records.delete"
    ]

    for operation <-
          (@mutation_operations -- supported) ++
            ["server.dns.records.list.extra", "dns.views.list"] do
      assert {:error, %Error{code: :unsupported, message: "unsupported operation", details: %{}}} =
               Dns.dispatch(operation, %{
                 "view_name" => "default",
                 "zone_name" => "example.test",
                 "record_id" => record_id("www", "A")
               })
    end

    assert {:error, %Error{code: :unsupported}} =
             Dns.current("server.dns.unknown", %{})

    for operation <- [
          "server.dns.zones.import",
          "server.dns.zones.sync",
          "server.dns.conflicts.resolve"
        ] do
      assert {:error, %Error{code: :unsupported}} = Dns.current(operation, %{})
    end

    assert [] = ServerDnsControlFake.take_calls()
  end

  defp list_result(items, revision) do
    %{"items" => items, "revision" => revision, "observed_at" => @observed_at}
  end

  defp assert_valid_result(name, result) do
    assert {:ok, operation} = ServerOperation.fetch(name)
    assert {:ok, ^result} = Operation.validate_result(operation, result)
  end

  defp dispatch_with_current_revision(operation, payload) do
    expected_revision =
      case Dns.current(operation, payload) do
        {:ok, :missing} ->
          nil

        {:ok, current} ->
          {:ok, revision} = Revision.calculate(current)
          revision
      end

    ServerDnsControlFake.take_calls()
    {:ok, payload_digest} = Digest.calculate(payload)

    Dispatcher.dispatch(%Envelope{
      protocol_version: 1,
      request_id: @request_id,
      target_type: :server,
      target_id: "server-task-3c",
      operation: operation,
      idempotency_key: @idempotency_key,
      payload: payload,
      payload_digest: payload_digest,
      expected_revision: expected_revision,
      config_version: nil,
      sent_at: @sent_at
    })
  end

  defp assert_dispatcher_dns_dependencies do
    assert [
             {:service_registry, :fetch, :dns},
             {:profile_resolver, :resolve}
           ] = YellowDog.ServerControlFake.take_dependency_calls()
  end

  defp mutation_state do
    ServerDnsControlFake.snapshot()
    |> Map.take([:zone_metadata, :record_state, :serial_advances])
  end

  defp record_id(owner, type) do
    digest = :crypto.hash(:sha256, canonical_owner(owner) <> <<0>> <> String.upcase(type))
    "rr-" <> Base.encode16(digest, case: :lower)
  end

  defp zone_payload do
    %{
      "view_name" => "default",
      "zone_name" => "example.test",
      "zone_type" => "authoritative",
      "provider_id" => nil
    }
  end

  defp authoritative_zone do
    %{view_name: "default", origin: "example.test", zone_type: :auth, soa: %{serial: 10}}
  end

  defp record_payload(type, values) do
    %{
      "view_name" => "default",
      "zone_name" => "example.test",
      "record_id" => record_id("www", type),
      "name" => "www",
      "type" => type,
      "ttl" => 60,
      "values" => values
    }
  end

  defp record_encodings do
    [
      {"A", :a, ["192.0.2.10"], [%{rdata: {192, 0, 2, 10}, ttl: 60}]},
      {"AAAA", :aaaa, ["2001:db8::10"], [%{rdata: {8193, 3512, 0, 0, 0, 0, 0, 16}, ttl: 60}]},
      {"CNAME", :cname, ["target.example.test."], [%{rdata: "target.example.test", ttl: 60}]},
      {"MX", :mx, ["10 mail.example.test."], [%{rdata: {10, "mail.example.test"}, ttl: 60}]},
      {"NS", :ns, ["ns1.example.test."], [%{rdata: "ns1.example.test", ttl: 60}]},
      {"PTR", :ptr, ["host.example.test."], [%{rdata: "host.example.test", ttl: 60}]},
      {"SRV", :srv, ["10 20 5060 sip.example.test."],
       [%{rdata: {10, 20, 5060, "sip.example.test"}, ttl: 60}]},
      {"TXT", :txt, ["hello"], [%{rdata: "hello", ttl: 60}]}
    ]
  end

  defp credential_ref(provider_id) do
    digest = :crypto.hash(:sha256, provider_id)
    "local-provider-" <> Base.encode16(digest, case: :lower)
  end

  defp provider_payload(provider_id) do
    %{
      "provider_id" => provider_id,
      "provider_type" => "cloudflare",
      "endpoint" => nil,
      "credential_ref" => credential_ref(provider_id)
    }
  end

  defp log_entry(id, qname, timestamp) do
    %{
      id: id,
      qname: qname,
      response_code: :noerror,
      resolution_type: :auth,
      timestamp: timestamp
    }
  end

  defp canonical_owner("@"), do: "@"

  defp canonical_owner(owner) do
    owner
    |> String.downcase()
    |> String.trim_trailing(".")
  end

  defp restore_env(module, nil), do: Application.delete_env(:yellow_dog, module)
  defp restore_env(module, config), do: Application.put_env(:yellow_dog, module, config)
end
