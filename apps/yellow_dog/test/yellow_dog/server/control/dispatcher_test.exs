defmodule YellowDog.Server.Control.DispatcherTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias YellowDog.Server.Control
  alias YellowDog.Server.Control.Dispatcher
  alias YellowDog.Server.Control.Revision
  alias YellowDog.Server.ServiceRegistry
  alias YellowDog.Sync.Digest
  alias YellowDog.Sync.Envelope
  alias YellowDog.Sync.Error
  alias YellowDog.Sync.Operation
  alias YellowDog.Sync.ServerOperation

  @request_id "00000000-0000-0000-0000-000000000001"
  @idempotency_key "00000000-0000-0000-0000-000000000002"
  @sent_at ~U[2026-07-16 00:00:00Z]
  @revision String.duplicate("a", 64)

  @fake_adapters %{
    runtime: YellowDog.ServerControlFake.Adapter.Runtime,
    dns: YellowDog.ServerControlFake.Adapter.Dns,
    dhcp: YellowDog.ServerControlFake.Adapter.Dhcp,
    mdns: YellowDog.ServerControlFake.Adapter.Mdns,
    netboot: YellowDog.ServerControlFake.Adapter.Netboot,
    identity: YellowDog.ServerControlFake.Adapter.Identity,
    settings: YellowDog.ServerControlFake.Adapter.Settings
  }

  setup do
    previous_dispatcher_config = Application.get_env(:yellow_dog, Dispatcher)

    put_dispatcher_config(adapters: @fake_adapters)

    on_exit(fn ->
      if is_nil(previous_dispatcher_config) do
        Application.delete_env(:yellow_dog, Dispatcher)
      else
        Application.put_env(:yellow_dog, Dispatcher, previous_dispatcher_config)
      end
    end)

    stop_config()
    start_supervised!({YellowDog.Config, enabled_config()})
    start_supervised!(YellowDog.ServerControlFake)
    :ok
  end

  test "accepts only direct Server envelopes revalidated through the exact Sync operation kind" do
    YellowDog.ServerControlFake.configure(:runtime,
      response: {:ok, %{capabilities: ["runtime.services"]}}
    )

    assert {:ok, %{"capabilities" => ["runtime.services"]}} =
             Control.dispatch(envelope("server.runtime.capabilities.get", %{}))

    assert_invalid(Control.dispatch(%{}))

    assert_invalid(
      Control.dispatch(envelope("server.runtime.capabilities.get", %{}, target_type: :netman))
    )

    assert_invalid(
      Control.dispatch(envelope("server.runtime.capabilities.get", %{}, request_id: "bad"))
    )

    assert_invalid(Control.dispatch(envelope("server.unknown.operation", %{})))

    assert_invalid(
      Control.dispatch(envelope("server.settings.update", %{"service" => "dns", "entries" => []}))
    )
  end

  test "rejects malformed payloads and caller-selected routing fields before adapter invocation" do
    payload = %{"service" => "dns", "module" => "Elixir.System", "function" => "halt"}

    assert_invalid(Control.dispatch(envelope("server.runtime.services.start", payload)))
    assert [] = YellowDog.ServerControlFake.take_calls()
  end

  test "routes every fixed operation domain to its distinct adapter" do
    listeners_before = listener_pids()
    adapter_error = Error.new(:not_found, "fake route", %{})
    public_error = Error.new(:not_found, "resource not found", %{})

    cases = [
      {:runtime, nil, "server.runtime.capabilities.get", %{}},
      {:dns, :dns, "server.dns.metrics.get", %{}},
      {:mdns, :mdns, "server.mdns.cache.get", %{}},
      {:netboot, :netboot, "server.netboot.profiles.list", %{}},
      {:identity, :identity, "server.identity.policies.get", %{}},
      {:settings, nil, "server.settings.source.get", %{"service" => "dns"}}
    ]

    for {route, service, operation, payload} <- cases do
      YellowDog.ServerControlFake.configure(route, response: {:error, adapter_error})

      assert {:error, ^public_error} = Control.dispatch(envelope(operation, payload))

      assert [{^route, :dispatch, ^operation, ^payload}] =
               YellowDog.ServerControlFake.take_calls()

      assert dependency_calls(service) == YellowDog.ServerControlFake.take_dependency_calls()
    end

    assert listener_pids() == listeners_before
  end

  test "routes both DHCP families through one fixed facade with payload unchanged" do
    adapter_error = Error.new(:not_found, "fake route", %{})
    public_error = Error.new(:not_found, "resource not found", %{})

    for {family, service} <- [{"ipv4", :dhcpv4}, {"ipv6", :dhcpv6}] do
      payload = %{"family" => family}
      YellowDog.ServerControlFake.configure(:dhcp, response: {:error, adapter_error})

      assert {:error, ^public_error} =
               Control.dispatch(envelope("server.dhcp.status.get", payload))

      assert [{:dhcp, :dispatch, "server.dhcp.status.get", ^payload}] =
               YellowDog.ServerControlFake.take_calls()

      assert dependency_calls(service) == YellowDog.ServerControlFake.take_dependency_calls()
    end
  end

  test "enabled and available services dispatch through the injected fixed dependencies" do
    adapter_error = Error.new(:not_found, "fake route", %{})
    public_error = Error.new(:not_found, "resource not found", %{})
    YellowDog.ServerControlFake.set_available(:dns, true)
    YellowDog.ServerControlFake.set_enabled(:dns, true)
    YellowDog.ServerControlFake.configure(:dns, response: {:error, adapter_error})

    assert {:error, ^public_error} =
             Control.dispatch(envelope("server.dns.metrics.get", %{}))

    assert [{:dns, :dispatch, "server.dns.metrics.get", %{}}] =
             YellowDog.ServerControlFake.take_calls()

    assert dependency_calls(:dns) == YellowDog.ServerControlFake.take_dependency_calls()
  end

  test "disabled services short-circuit without adapter invocation" do
    YellowDog.ServerControlFake.set_available(:dns, true)
    YellowDog.ServerControlFake.set_enabled(:dns, false)

    assert_unsupported(Control.dispatch(envelope("server.dns.metrics.get", %{})))
    assert [] = YellowDog.ServerControlFake.take_calls()
    assert dependency_calls(:dns) == YellowDog.ServerControlFake.take_dependency_calls()
  end

  test "unavailable services short-circuit without resolver or adapter invocation" do
    YellowDog.ServerControlFake.set_available(:dns, false)
    YellowDog.ServerControlFake.set_enabled(:dns, true)

    assert_unsupported(Control.dispatch(envelope("server.dns.metrics.get", %{})))
    assert [] = YellowDog.ServerControlFake.take_calls()

    assert [{:service_registry, :fetch, :dns}] =
             YellowDog.ServerControlFake.take_dependency_calls()
  end

  test "returns unsupported when a known fixed route has no adapter" do
    put_dispatcher_config(adapters: %{settings: YellowDog.ServerControlFake.MissingAdapter})

    assert_unsupported(
      Control.dispatch(envelope("server.settings.source.get", %{"service" => "dns"}))
    )

    assert [] = YellowDog.ServerControlFake.take_calls()
  end

  test "rejects test adapter overrides outside the fixed route keys" do
    for route_key <- [:caller_selected, :dhcpv4, :dhcpv6] do
      put_dispatcher_config(adapters: %{route_key => YellowDog.ServerControlFake.Adapter.Runtime})

      assert_internal(Control.dispatch(envelope("server.runtime.capabilities.get", %{})))
      assert [] = YellowDog.ServerControlFake.take_calls()
    end
  end

  test "rejects stale revisions before mutation and reports the current revision" do
    current = %{
      service: "dns",
      state: :running,
      revision: String.duplicate("0", 64),
      observed_at: ~U[2026-07-15 23:59:00Z]
    }

    assert {:ok, current_revision} = Revision.calculate(current)

    YellowDog.ServerControlFake.configure(:runtime,
      current: {:ok, current},
      response: {:ok, %{service: "dns", state: :stopped}}
    )

    assert {:error,
            %Error{
              code: :conflict,
              message: "stale revision",
              details: %{
                "expected_revision" => @revision,
                "current_revision" => ^current_revision
              }
            }} =
             Control.dispatch(
               envelope("server.runtime.services.stop", %{"service" => "dns"},
                 expected_revision: @revision
               )
             )

    assert [{:runtime, :current, "server.runtime.services.stop", %{"service" => "dns"}}] =
             YellowDog.ServerControlFake.take_calls()
  end

  test "allows matching revisions and invokes the mutation exactly once" do
    current = %{service: "dns", state: :running}
    assert {:ok, current_revision} = Revision.calculate(current)

    YellowDog.ServerControlFake.configure(:runtime,
      current: {:ok, current},
      response: {:ok, %{service: "dns", state: :stopped}}
    )

    assert {:ok, %{"service" => "dns", "state" => "stopped"}} =
             Control.dispatch(
               envelope("server.runtime.services.stop", %{"service" => "dns"},
                 expected_revision: current_revision
               )
             )

    assert [
             {:runtime, :current, "server.runtime.services.stop", %{"service" => "dns"}},
             {:runtime, :dispatch, "server.runtime.services.stop", %{"service" => "dns"}}
           ] = YellowDog.ServerControlFake.take_calls()
  end

  test "serializes revision checks with mutation dispatch" do
    owner = self()
    current = %{service: "dns", state: :running}
    updated = %{service: "dns", state: :stopped}
    assert {:ok, expected_revision} = Revision.calculate(current)
    assert {:ok, updated_revision} = Revision.calculate(updated)

    YellowDog.ServerControlFake.configure(:runtime,
      current: {:ok, current},
      response: {:block, owner, updated, {:ok, updated}}
    )

    first =
      Task.async(fn ->
        Control.dispatch(
          envelope("server.runtime.services.stop", %{"service" => "dns"},
            expected_revision: expected_revision,
            request_id: "00000000-0000-0000-0000-000000000003",
            idempotency_key: "00000000-0000-0000-0000-000000000004"
          )
        )
      end)

    assert_receive {:dispatch_blocked, :runtime, first_dispatcher}, 1_000

    second =
      Task.async(fn ->
        send(owner, :second_dispatch_started)

        Control.dispatch(
          envelope("server.runtime.services.stop", %{"service" => "dns"},
            expected_revision: expected_revision,
            request_id: "00000000-0000-0000-0000-000000000005",
            idempotency_key: "00000000-0000-0000-0000-000000000006"
          )
        )
      end)

    assert_receive :second_dispatch_started, 1_000
    refute_receive {:dispatch_blocked, :runtime, _second_dispatcher}, 250
    send(first_dispatcher, {:release_dispatch, :runtime})

    assert {:ok, %{"service" => "dns", "state" => "stopped"}} = Task.await(first, 1_000)

    assert {:error,
            %Error{
              code: :conflict,
              details: %{
                "expected_revision" => ^expected_revision,
                "current_revision" => ^updated_revision
              }
            }} = Task.await(second, 1_000)

    calls = YellowDog.ServerControlFake.take_calls()
    assert Enum.count(calls, &match?({:runtime, :dispatch, _, _}, &1)) == 1

    assert [
             {:runtime, :current, "server.runtime.services.stop", %{"service" => "dns"}},
             {:runtime, :dispatch, "server.runtime.services.stop", %{"service" => "dns"}},
             {:runtime, :current, "server.runtime.services.stop", %{"service" => "dns"}}
           ] = calls
  end

  test "queries remain direct while a mutation owns the serialization boundary" do
    owner = self()
    current = %{service: "dns", state: :running}
    updated = %{service: "dns", state: :stopped}
    query_error = Error.new(:not_found, "query completed", %{})
    public_query_error = Error.new(:not_found, "resource not found", %{})
    assert {:ok, expected_revision} = Revision.calculate(current)

    YellowDog.ServerControlFake.configure(:runtime,
      current: {:ok, current},
      response: {:block, owner, updated, {:ok, updated}}
    )

    YellowDog.ServerControlFake.configure(:settings, response: {:error, query_error})

    mutation =
      Task.async(fn ->
        Control.dispatch(
          envelope("server.runtime.services.stop", %{"service" => "dns"},
            expected_revision: expected_revision
          )
        )
      end)

    assert_receive {:dispatch_blocked, :runtime, mutation_dispatcher}, 1_000

    query =
      Task.async(fn ->
        Control.dispatch(envelope("server.settings.source.get", %{"service" => "dns"}))
      end)

    assert {:error, ^public_query_error} = Task.await(query, 500)
    send(mutation_dispatcher, {:release_dispatch, :runtime})
    assert {:ok, %{"service" => "dns", "state" => "stopped"}} = Task.await(mutation, 1_000)
  end

  test "rejects oversized and operation-invalid normalized adapter results" do
    invalid_results = [
      %{capabilities: [String.duplicate("x", 1_025)]},
      %{capabilities: [], unexpected: true}
    ]

    for result <- invalid_results do
      YellowDog.ServerControlFake.configure(:runtime, response: {:ok, result})

      assert_invalid(Control.dispatch(envelope("server.runtime.capabilities.get", %{})))

      assert [{:runtime, :dispatch, "server.runtime.capabilities.get", %{}}] =
               YellowDog.ServerControlFake.take_calls()
    end
  end

  test "rejects a schema-valid Netboot log containing an absolute local path" do
    leaked_path = "/var/lib/yellowdog/netboot/assets/installer.img"

    result = %{
      "items" => [
        %{
          "log_id" => "log-1",
          "device_id" => "device-1",
          "message" => "failed to serve #{leaked_path}",
          "occurred_at" => "2026-07-16T00:00:00Z"
        }
      ],
      "revision" => @revision,
      "observed_at" => "2026-07-16T00:00:00Z"
    }

    assert {:ok, operation} = ServerOperation.fetch("server.netboot.logs.list")
    assert {:ok, ^result} = Operation.validate_result(operation, result)

    YellowDog.ServerControlFake.configure(:netboot, response: {:ok, result})

    response = Control.dispatch(envelope("server.netboot.logs.list", %{}))
    assert_invalid(response)
    refute inspect(response) =~ leaked_path
  end

  test "redacts sensitive values in effective managed settings" do
    secret = "server-control-secret"
    nested_secret = "token=nested-server-control-secret"

    result = %{
      "service" => "dns",
      "entries" => [
        %{
          "key" => "password",
          "value" => %{"type" => "string", "value" => secret}
        },
        %{
          "key" => "database",
          "value" => %{
            "type" => "object",
            "entries" => [
              %{
                "key" => "api_key",
                "value" => %{"type" => "string", "value" => nested_secret}
              }
            ]
          }
        }
      ]
    }

    assert {:ok, operation} = ServerOperation.fetch("server.settings.effective.get")
    assert {:ok, ^result} = Operation.validate_result(operation, result)
    YellowDog.ServerControlFake.configure(:settings, response: {:ok, result})

    assert {:ok,
            %{
              "service" => "dns",
              "entries" => [
                %{
                  "key" => "password",
                  "value" => %{"type" => "string", "value" => "[redacted]"}
                },
                %{
                  "key" => "database",
                  "value" => %{
                    "type" => "object",
                    "entries" => [
                      %{
                        "key" => "api_key",
                        "value" => %{"type" => "string", "value" => "[redacted]"}
                      }
                    ]
                  }
                }
              ]
            } = redacted} =
             Control.dispatch(envelope("server.settings.effective.get", %{"service" => "dns"}))

    assert {:ok, ^redacted} = Operation.validate_result(operation, redacted)
    refute inspect(redacted) =~ secret
    refute inspect(redacted) =~ nested_secret
  end

  test "preserves safe managed setting references containing URL paths" do
    uri = "https://provider.example.test/api?next=/console"

    result = %{
      "service" => "dns",
      "entries" => [
        %{
          "key" => "client_secret_key_uri",
          "value" => %{"type" => "string", "value" => uri}
        }
      ]
    }

    assert {:ok, operation} = ServerOperation.fetch("server.settings.effective.get")
    assert {:ok, ^result} = Operation.validate_result(operation, result)
    YellowDog.ServerControlFake.configure(:settings, response: {:ok, result})

    assert {:ok, ^result} =
             Control.dispatch(envelope("server.settings.effective.get", %{"service" => "dns"}))
  end

  test "preserves the deliberate one-time Identity token secret" do
    secret = "server-control-one-time-secret"

    result = %{
      "token_id" => "token-1",
      "secret" => secret,
      "expires_at" => nil
    }

    assert {:ok, operation} = ServerOperation.fetch("server.identity.tokens.create")
    assert {:ok, ^result} = Operation.validate_result(operation, result)

    YellowDog.ServerControlFake.configure(:identity,
      current: {:ok, :missing},
      response: {:ok, result}
    )

    assert {:ok, ^result} =
             Control.dispatch(
               envelope("server.identity.tokens.create", %{
                 "token_id" => "token-1",
                 "label" => "automation",
                 "expires_at" => nil
               })
             )
  end

  test "rebuilds typed adapter errors without leaking message or details" do
    leaked_token = "token=server-control-secret"
    leaked_path = "/var/lib/yellowdog/runtime/state.json"

    adapter_error =
      Error.new(:timeout, "adapter timed out: #{leaked_token}", %{
        "diagnostic" => "failed to read #{leaked_path}"
      })

    YellowDog.ServerControlFake.configure(:runtime, response: {:error, adapter_error})

    assert {:error,
            %Error{code: :timeout, message: "operation timed out", details: %{}} = public_error} =
             response = Control.dispatch(envelope("server.runtime.capabilities.get", %{}))

    refute inspect(response) =~ leaked_token
    refute inspect(response) =~ leaked_path
    assert {:ok, ^public_error} = public_error |> Error.to_wire() |> Error.from_wire()
  end

  test "redacts mutation failures and releases serialization after raise, throw, and exit" do
    current = %{service: "dns", state: :running}
    result = %{service: "dns", state: :stopped}
    assert {:ok, expected_revision} = Revision.calculate(current)

    for failure <- [:raise, :throw, :exit] do
      secret = "#{failure}-adapter-secret"

      YellowDog.ServerControlFake.configure(:runtime,
        current: {:ok, current},
        response: {failure, secret}
      )

      log =
        capture_log(fn ->
          assert_internal(
            Control.dispatch(
              envelope("server.runtime.services.stop", %{"service" => "dns"},
                expected_revision: expected_revision
              )
            )
          )
        end)

      assert log =~ secret

      YellowDog.ServerControlFake.configure(:runtime, response: {:ok, result})

      follow_up =
        Task.async(fn ->
          Control.dispatch(
            envelope("server.runtime.services.stop", %{"service" => "dns"},
              expected_revision: expected_revision
            )
          )
        end)

      assert {:ok, %{"service" => "dns", "state" => "stopped"}} =
               Task.await(follow_up, 1_000)

      assert [
               {:runtime, :current, "server.runtime.services.stop", %{"service" => "dns"}},
               {:runtime, :dispatch, "server.runtime.services.stop", %{"service" => "dns"}},
               {:runtime, :current, "server.runtime.services.stop", %{"service" => "dns"}},
               {:runtime, :dispatch, "server.runtime.services.stop", %{"service" => "dns"}}
             ] = YellowDog.ServerControlFake.take_calls()
    end
  end

  test "unknown operation input does not grow the atom table" do
    assert_invalid(Control.dispatch(envelope("server.unknown.warmup", %{})))
    :erlang.garbage_collect()
    atom_count = :erlang.system_info(:atom_count)

    last_operation =
      Enum.reduce(1..500, nil, fn index, _last ->
        operation = "server.unknown.#{index}_#{System.unique_integer([:positive])}"
        assert_invalid(Control.dispatch(envelope(operation, %{})))
        operation
      end)

    :erlang.garbage_collect()
    assert :erlang.system_info(:atom_count) == atom_count
    assert_raise ArgumentError, fn -> String.to_existing_atom(last_operation) end
  end

  defp envelope(operation, payload, overrides \\ []) do
    {:ok, payload_digest} = Digest.calculate(payload)

    %Envelope{
      protocol_version: 1,
      request_id: Keyword.get(overrides, :request_id, @request_id),
      target_type: Keyword.get(overrides, :target_type, :server),
      target_id: "server-east-1",
      operation: operation,
      idempotency_key: Keyword.get(overrides, :idempotency_key, @idempotency_key),
      payload: payload,
      payload_digest: payload_digest,
      expected_revision: Keyword.get(overrides, :expected_revision),
      config_version: Keyword.get(overrides, :config_version),
      sent_at: @sent_at
    }
  end

  defp put_dispatcher_config(overrides) do
    defaults = [
      service_registry: YellowDog.ServerControlFake.ServiceRegistry,
      profile_resolver: YellowDog.ServerControlFake.ProfileResolver
    ]

    Application.put_env(:yellow_dog, Dispatcher, Keyword.merge(defaults, overrides))
  end

  defp dependency_calls(nil), do: []

  defp dependency_calls(service) do
    [
      {:service_registry, :fetch, service},
      {:profile_resolver, :resolve}
    ]
  end

  defp enabled_config do
    %{"yellow_dog_server" => %{"profile" => "local_network"}}
  end

  defp listener_pids do
    Map.new(ServiceRegistry.all(), fn metadata ->
      {metadata.name, Process.whereis(metadata.process_name)}
    end)
  end

  defp stop_config do
    case Process.whereis(YellowDog.Config) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end
  end

  defp assert_invalid({:error, %Error{code: :invalid}}), do: :ok
  defp assert_invalid(other), do: flunk("expected invalid error, got: #{inspect(other)}")

  defp assert_unsupported({:error, %Error{code: :unsupported}}), do: :ok

  defp assert_unsupported(other),
    do: flunk("expected unsupported error, got: #{inspect(other)}")

  defp assert_internal(
         {:error, %Error{code: :internal, message: "internal error", details: %{}}}
       ),
       do: :ok

  defp assert_internal(other), do: flunk("expected internal error, got: #{inspect(other)}")
end
