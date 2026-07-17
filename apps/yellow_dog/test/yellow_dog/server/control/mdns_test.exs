defmodule YellowDog.Server.Control.MdnsTest do
  use ExUnit.Case, async: false

  alias YellowDog.Server.Control.Dispatcher
  alias YellowDog.Server.Control.Mdns
  alias YellowDog.Server.Control.Revision
  alias YellowDog.ServerMdnsControlFake
  alias YellowDog.Sync.Digest
  alias YellowDog.Sync.Envelope
  alias YellowDog.Sync.Error
  alias YellowDog.Sync.Operation
  alias YellowDog.Sync.ServerOperation

  @request_id "00000000-0000-0000-0000-00000000005c"
  @idempotency_key "00000000-0000-0000-0000-00000000005d"
  @sent_at ~U[2026-07-17 00:00:00Z]
  @observed_at "2026-07-17T00:00:00Z"

  setup do
    previous_mdns = Application.get_env(:yellow_dog, Mdns)
    previous_dispatcher = Application.get_env(:yellow_dog, Dispatcher)

    Application.put_env(:yellow_dog, Mdns,
      registry: YellowDog.ServerMdnsControlFake.Registry,
      cache: YellowDog.ServerMdnsControlFake.Cache,
      monitor: YellowDog.ServerMdnsControlFake.Monitor,
      clock: YellowDog.ServerMdnsControlFake.Clock
    )

    Application.put_env(:yellow_dog, Dispatcher,
      adapters: %{mdns: Mdns},
      service_registry: YellowDog.ServerControlFake.ServiceRegistry,
      profile_resolver: YellowDog.ServerControlFake.ProfileResolver
    )

    start_supervised!(ServerMdnsControlFake)
    start_supervised!(YellowDog.ServerControlFake)

    on_exit(fn ->
      restore_env(Mdns, previous_mdns)
      restore_env(Dispatcher, previous_dispatcher)
    end)

    :ok
  end

  test "projects sorted bounded services with a stable canonical revision" do
    services = [service("beta"), service("alpha")]
    ServerMdnsControlFake.configure(%{registry_snapshot: {:ok, services}})

    assert {:ok, result} = Mdns.dispatch("server.mdns.services.list", %{"limit" => 1})
    assert result["items"] == [public_service("alpha")]
    assert result["observed_at"] == @observed_at

    assert {:ok, revision} = Revision.calculate([public_service("alpha"), public_service("beta")])
    assert result["revision"] == revision
    assert_valid_result("server.mdns.services.list", result)

    assert [
             {:registry, :control_snapshot, []},
             {:clock, :utc_now, []}
           ] = ServerMdnsControlFake.take_calls()
  end

  test "projects one sorted discovery item per valid address and omits malformed entries" do
    ServerMdnsControlFake.configure(%{
      discovery_list: [
        %{
          service_id: "beta._http._tcp.local",
          type: "_http._tcp",
          addresses: [{8193, 3512, 0, 0, 0, 0, 0, 2}]
        },
        %{
          service_id: "alpha._http._tcp.local",
          type: "_http._tcp",
          addresses: [{192, 0, 2, 10}, :invalid]
        },
        %{service_id: "broken", type: "not-a-service", addresses: [{192, 0, 2, 11}]}
      ]
    })

    assert {:ok, result} = Mdns.dispatch("server.mdns.discovery.list", %{})

    assert result["items"] == [
             %{
               "name" => "alpha._http._tcp.local",
               "service_type" => "_http._tcp",
               "address" => "192.0.2.10"
             },
             %{
               "name" => "beta._http._tcp.local",
               "service_type" => "_http._tcp",
               "address" => "2001:db8::2"
             }
           ]

    assert_valid_result("server.mdns.discovery.list", result)
  end

  test "validates monitor payload then returns typed unsupported without owner calls" do
    assert {:error, %Error{code: :unsupported}} = Mdns.dispatch("server.mdns.monitor.list", %{})
    assert [] = ServerMdnsControlFake.take_calls()

    assert {:error, %Error{code: :invalid}} =
             Mdns.dispatch("server.mdns.monitor.list", %{"limit" => 0})

    assert [] = ServerMdnsControlFake.take_calls()
  end

  test "uses public resource plus enabled state for mutation revisions" do
    prior = service("printer", enabled: false)
    updated = service("printer", port: 9101, enabled: true)

    ServerMdnsControlFake.configure(%{
      registry_snapshot: {:ok, [prior]},
      registry_update: {:ok, [prior], [updated]}
    })

    payload = public_service("printer") |> Map.put("service_port", 9101)
    current = %{"resource" => public_service("printer"), "enabled" => false}
    assert {:ok, expected_revision} = Revision.calculate(current)

    assert {:ok, result} =
             Dispatcher.dispatch(
               envelope("server.mdns.services.update", payload,
                 expected_revision: expected_revision
               )
             )

    assert result["resource"] == public_service("printer") |> Map.put("service_port", 9101)

    assert {:ok, result_revision} =
             Revision.calculate(%{"resource" => result["resource"], "enabled" => true})

    assert result["revision"] == result_revision

    assert [
             {:registry, :control_snapshot, []},
             {:registry, :control_update_service, ["printer._http._tcp.local", _service]}
           ] = ServerMdnsControlFake.take_calls()
  end

  test "clears cache after a revision check against the canonical bounded entries object" do
    entries = [
      %{"name" => "z.example.local", "type" => "A", "values" => ["192.0.2.20"]},
      %{"name" => "a.example.local", "type" => "A", "values" => ["192.0.2.10"]}
    ]

    ServerMdnsControlFake.configure(%{
      cache_snapshot: {:ok, entries},
      cache_clear: {:ok, 2}
    })

    current = %{"entries" => Enum.sort_by(entries, &{&1["name"], &1["type"], &1["values"]})}
    assert {:ok, expected_revision} = Revision.calculate(current)

    assert {:ok, %{"cleared_entries" => 2}} =
             Dispatcher.dispatch(
               envelope("server.mdns.cache.clear", %{}, expected_revision: expected_revision)
             )

    assert [
             {:cache, :control_snapshot, []},
             {:cache, :control_clear, []}
           ] = ServerMdnsControlFake.take_calls()
  end

  test "returns the same sorted bounded cache object from cache get and current" do
    entries = [
      %{"name" => "z.example.local", "type" => "A", "values" => ["192.0.2.20"]},
      %{"name" => "a.example.local", "type" => "AAAA", "values" => ["2001:db8::10"]}
    ]

    ServerMdnsControlFake.configure(%{cache_snapshot: {:ok, entries}})

    assert {:ok, %{"entries" => expected}} = Mdns.dispatch("server.mdns.cache.get", %{})
    assert {:ok, %{"entries" => ^expected}} = Mdns.current("server.mdns.cache.clear", %{})
    assert_valid_result("server.mdns.cache.get", %{"entries" => expected})

    assert [
             {:cache, :control_snapshot, []},
             {:cache, :control_snapshot, []}
           ] = ServerMdnsControlFake.take_calls()
  end

  test "registers, toggles, and deletes exact revisioned service resources" do
    enabled = service("printer")
    disabled = service("printer", enabled: false)

    ServerMdnsControlFake.configure(%{
      registry_snapshot: {:ok, []},
      registry_register: {:ok, [], [enabled]},
      registry_toggle: {:ok, [enabled], [disabled]},
      registry_delete: {:ok, [disabled], []}
    })

    payload = public_service("printer")
    assert {:ok, :missing} = Mdns.current("server.mdns.services.register", payload)
    ServerMdnsControlFake.take_calls()

    assert {:ok, registered} = Mdns.dispatch("server.mdns.services.register", payload)
    assert registered["resource"] == payload

    assert {:ok, registered_revision} =
             Revision.calculate(%{"resource" => payload, "enabled" => true})

    assert registered["revision"] == registered_revision

    ServerMdnsControlFake.configure(%{registry_snapshot: {:ok, [enabled]}})
    toggle_payload = %{"service_id" => payload["service_id"], "enabled" => false}

    assert {:ok, current} = Mdns.current("server.mdns.services.toggle", toggle_payload)
    assert current == %{"resource" => payload, "enabled" => true}

    assert {:ok, toggled} = Mdns.dispatch("server.mdns.services.toggle", toggle_payload)
    assert toggled["resource"] == payload

    assert {:ok, toggled_revision} =
             Revision.calculate(%{"resource" => payload, "enabled" => false})

    assert toggled["revision"] == toggled_revision

    ServerMdnsControlFake.configure(%{registry_snapshot: {:ok, [disabled]}})
    delete_payload = %{"service_id" => payload["service_id"]}

    assert {:ok, %{"resource" => ^payload, "enabled" => false}} =
             Mdns.current("server.mdns.services.delete", delete_payload)

    assert {:ok, deleted} = Mdns.dispatch("server.mdns.services.delete", delete_payload)
    assert deleted["resource_ref"] == delete_payload
    assert_valid_result("server.mdns.services.delete", deleted)
  end

  test "maps owner absence and unexpected failures to sanitized typed errors" do
    ServerMdnsControlFake.configure(%{registry_snapshot: {:error, :registry_absent}})

    assert {:error, %Error{code: :not_found, message: "resource not found", details: %{}}} =
             Mdns.dispatch("server.mdns.services.list", %{})

    ServerMdnsControlFake.configure(%{
      registry_snapshot: {:error, {:leaked, "/var/lib/yellowdog"}}
    })

    assert {:error, %Error{code: :apply_failed, message: "apply failed", details: %{}}} =
             response =
             Mdns.dispatch("server.mdns.services.list", %{})

    refute inspect(response) =~ "/var/lib/yellowdog"
  end

  test "rejects invalid payloads before owner calls" do
    assert {:error, %Error{code: :invalid}} =
             Mdns.dispatch("server.mdns.services.register", %{
               "service_id" => "wrong._http._tcp.local",
               "name" => "wrong",
               "service_type" => "_http._tcp",
               "service_port" => 0,
               "txt" => []
             })

    assert {:error, %Error{code: :invalid}} =
             Mdns.current("server.mdns.cache.clear", %{"extra" => true})

    assert {:error, %Error{code: :invalid}} =
             Mdns.current(
               "server.mdns.services.register",
               %{public_service("printer") | "service_id" => "other._http._tcp.local"}
             )

    assert [] = ServerMdnsControlFake.take_calls()
  end

  test "Dispatcher service availability and profile gates short-circuit before the mDNS owner" do
    YellowDog.ServerControlFake.set_available(:mdns, false)

    assert {:error, %Error{code: :unsupported}} =
             Dispatcher.dispatch(envelope("server.mdns.services.list", %{}))

    assert [] = ServerMdnsControlFake.take_calls()

    YellowDog.ServerControlFake.set_available(:mdns, true)
    YellowDog.ServerControlFake.set_enabled(:mdns, false)

    assert {:error, %Error{code: :unsupported}} =
             Dispatcher.dispatch(envelope("server.mdns.services.list", %{}))

    assert [] = ServerMdnsControlFake.take_calls()
  end

  test "duplicate register and immutable identity owner results are typed invalid or conflict" do
    service = service("printer")
    ServerMdnsControlFake.configure(%{registry_register: {:error, :already_exists}})

    assert {:error, %Error{code: :conflict}} =
             Mdns.dispatch("server.mdns.services.register", public_service("printer"))

    ServerMdnsControlFake.configure(%{registry_update: {:error, :immutable_identity}})

    assert {:error, %Error{code: :invalid}} =
             Mdns.dispatch("server.mdns.services.update", public_service("printer"))

    assert [
             {:registry, :control_register_service, ["printer._http._tcp.local", _]},
             {:registry, :control_update_service, ["printer._http._tcp.local", _]}
           ] = ServerMdnsControlFake.take_calls()

    assert service.id == "printer._http._tcp.local"
  end

  defp service(name, overrides \\ []) do
    %{
      id: "#{name}._http._tcp.local",
      name: name,
      type: "_http._tcp",
      port: Keyword.get(overrides, :port, 9100),
      txt_records: %{"note" => "office", "room" => "north"},
      enabled: Keyword.get(overrides, :enabled, true),
      registered_at: self(),
      cache_path: "/var/lib/yellowdog/ignored"
    }
  end

  defp public_service(name) do
    %{
      "service_id" => "#{name}._http._tcp.local",
      "name" => name,
      "service_type" => "_http._tcp",
      "service_port" => 9100,
      "txt" => [
        %{"key" => "note", "value" => "office"},
        %{"key" => "room", "value" => "north"}
      ]
    }
  end

  defp envelope(operation, payload, overrides \\ []) do
    {:ok, payload_digest} = Digest.calculate(payload)

    %Envelope{
      protocol_version: 1,
      request_id: @request_id,
      target_type: :server,
      target_id: "server-task-5c",
      operation: operation,
      idempotency_key: @idempotency_key,
      payload: payload,
      payload_digest: payload_digest,
      expected_revision: Keyword.get(overrides, :expected_revision),
      config_version: nil,
      sent_at: @sent_at
    }
  end

  defp assert_valid_result(operation_name, result) do
    assert {:ok, operation} = ServerOperation.fetch(operation_name)
    assert {:ok, ^result} = Operation.validate_result(operation, result)
  end

  defp restore_env(module, nil), do: Application.delete_env(:yellow_dog, module)
  defp restore_env(module, config), do: Application.put_env(:yellow_dog, module, config)
end
