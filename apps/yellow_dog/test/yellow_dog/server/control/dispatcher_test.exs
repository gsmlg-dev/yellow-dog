defmodule YellowDog.Server.Control.DispatcherTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias YellowDog.Server.Control
  alias YellowDog.Server.Control.Revision
  alias YellowDog.Server.ServiceRegistry
  alias YellowDog.Sync.Digest
  alias YellowDog.Sync.Envelope
  alias YellowDog.Sync.Error

  @request_id "00000000-0000-0000-0000-000000000001"
  @idempotency_key "00000000-0000-0000-0000-000000000002"
  @sent_at ~U[2026-07-16 00:00:00Z]
  @revision String.duplicate("a", 64)

  setup do
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

  test "routes runtime through its fixed adapter without starting protocol listeners" do
    listeners_before = listener_pids()
    operation = "server.runtime.capabilities.get"
    payload = %{}

    YellowDog.ServerControlFake.configure(:runtime,
      response: {:ok, %{capabilities: ["runtime.services"]}}
    )

    assert {:ok, %{"capabilities" => ["runtime.services"]}} =
             Control.dispatch(envelope(operation, payload))

    assert [{:runtime, :dispatch, ^operation, ^payload}] =
             YellowDog.ServerControlFake.take_calls()

    assert listener_pids() == listeners_before
  end

  test "returns unsupported for a disabled service without invoking its adapter" do
    Agent.update(YellowDog.Config, fn _config ->
      %{
        "yellow_dog_server" => %{
          "profile" => "custom",
          "services" => %{"dns" => false}
        }
      }
    end)

    assert_unsupported(Control.dispatch(envelope("server.dns.metrics.get", %{})))
    assert [] = YellowDog.ServerControlFake.take_calls()
  end

  test "returns unsupported for unavailable fixed protocol domains without invocation" do
    cases = [
      {:dns, "server.dns.metrics.get", %{}},
      {:mdns, "server.mdns.cache.get", %{}},
      {:dhcpv4, "server.dhcp.status.get", %{"family" => "ipv4"}},
      {:dhcpv6, "server.dhcp.status.get", %{"family" => "ipv6"}},
      {:netboot, "server.netboot.profiles.list", %{}},
      {:identity, "server.identity.policies.get", %{}}
    ]

    for {service, operation, payload} <- cases do
      assert {:ok, %{available?: false}} = ServiceRegistry.fetch(service)
      assert_unsupported(Control.dispatch(envelope(operation, payload)))
    end

    assert [] = YellowDog.ServerControlFake.take_calls()
  end

  test "returns unsupported when the fixed adapter has not been created" do
    refute Code.ensure_loaded?(YellowDog.Server.Control.Settings)

    assert_unsupported(
      Control.dispatch(envelope("server.settings.source.get", %{"service" => "dns"}))
    )

    assert [] = YellowDog.ServerControlFake.take_calls()
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

  test "preserves validated typed adapter errors" do
    adapter_error = Error.new(:timeout, "adapter timed out", %{"retryable" => true})
    YellowDog.ServerControlFake.configure(:runtime, response: {:error, adapter_error})

    assert {:error, ^adapter_error} =
             Control.dispatch(envelope("server.runtime.capabilities.get", %{}))
  end

  test "redacts raise, throw, and exit details from returned internal errors" do
    for failure <- [:raise, :throw, :exit] do
      secret = "#{failure}-adapter-secret"
      YellowDog.ServerControlFake.configure(:runtime, response: {failure, secret})

      log =
        capture_log(fn ->
          assert {:error,
                  %Error{code: :internal, message: "internal error", details: %{}} = error} =
                   Control.dispatch(envelope("server.runtime.capabilities.get", %{}))

          refute inspect(error) =~ secret
        end)

      assert log =~ secret

      assert [{:runtime, :dispatch, "server.runtime.capabilities.get", %{}}] =
               YellowDog.ServerControlFake.take_calls()
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
      idempotency_key: @idempotency_key,
      payload: payload,
      payload_digest: payload_digest,
      expected_revision: Keyword.get(overrides, :expected_revision),
      config_version: Keyword.get(overrides, :config_version),
      sent_at: @sent_at
    }
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
end
