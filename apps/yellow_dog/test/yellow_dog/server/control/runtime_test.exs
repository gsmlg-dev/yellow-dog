defmodule YellowDog.Server.Control.RuntimeTest do
  use ExUnit.Case, async: false

  alias YellowDog.Server.Control
  alias YellowDog.Server.Control.Dispatcher
  alias YellowDog.Server.Control.Revision
  alias YellowDog.Server.Control.Runtime
  alias YellowDog.ServerRuntimeControlFake
  alias YellowDog.Sync.Envelope
  alias YellowDog.Sync.Error

  @request_id "00000000-0000-0000-0000-000000000101"
  @idempotency_key "00000000-0000-0000-0000-000000000102"
  @sent_at ~U[2026-07-16 00:00:00Z]

  setup do
    previous_runtime_config = Application.get_env(:yellow_dog, Runtime)
    previous_dispatcher_config = Application.get_env(:yellow_dog, Dispatcher)

    Application.put_env(:yellow_dog, Runtime,
      service_manager: ServerRuntimeControlFake.ServiceManager,
      service_registry: ServerRuntimeControlFake.ServiceRegistry
    )

    start_supervised!(ServerRuntimeControlFake)

    on_exit(fn ->
      restore_env(Runtime, previous_runtime_config)
      restore_env(Dispatcher, previous_dispatcher_config)
    end)

    :ok
  end

  test "maps runtime reads to exact wire shapes without runtime metadata" do
    assert {:ok,
            %{
              "capabilities" => [
                "runtime.capabilities",
                "runtime.health",
                "runtime.services",
                "runtime.stats"
              ]
            }} = Runtime.dispatch("server.runtime.capabilities.get", %{})

    assert {:ok,
            %{
              "items" => [
                %{"service" => "dns", "state" => "running"},
                %{"service" => "server_agent", "state" => "failed"}
              ],
              "next_cursor" => nil
            }} = Runtime.dispatch("server.runtime.services.list", %{})

    assert {:ok,
            %{
              "status" => "degraded",
              "checks" => [
                %{"name" => "dns", "status" => "healthy"},
                %{"name" => "server_agent", "status" => "unhealthy"}
              ]
            }} = Runtime.dispatch("server.runtime.health.get", %{})

    assert {:ok, %{"requests" => 0, "errors" => 1}} =
             Runtime.dispatch("server.runtime.stats.get", %{})
  end

  test "resolves only fixed registry service names without creating atoms" do
    assert {:ok, _} = Runtime.dispatch("server.runtime.capabilities.get", %{})
    assert {:error, _} = Runtime.dispatch("server.runtime.services.start", %{"service" => "warm"})
    initial_atom_count = :erlang.system_info(:atom_count)

    assert {:error, %Error{code: :unsupported}} =
             Runtime.dispatch("server.runtime.services.start", %{
               "service" => "new-runtime-service"
             })

    assert :erlang.system_info(:atom_count) == initial_atom_count
    assert [] = ServerRuntimeControlFake.take_calls()
  end

  test "rejects unavailable services without a ServiceManager mutation" do
    assert {:error, %Error{code: :unsupported}} =
             Runtime.dispatch("server.runtime.services.start", %{"service" => "server_agent"})

    assert [] = ServerRuntimeControlFake.take_calls()
  end

  test "starts and stops a controllable service with current resource snapshots" do
    assert {:ok, %{"service" => "dns", "state" => "running"}} =
             Runtime.current("server.runtime.services.stop", %{"service" => "dns"})

    assert {:ok, %{"service" => "dns", "state" => "stopped"}} =
             Runtime.dispatch("server.runtime.services.stop", %{"service" => "dns"})

    assert {:ok, %{"service" => "dns", "state" => "running"}} =
             Runtime.dispatch("server.runtime.services.start", %{"service" => "dns"})

    assert [stop: :dns, start: :dns] = ServerRuntimeControlFake.take_calls()
  end

  test "restart preserves bounded phase outcomes when the start phase fails" do
    ServerRuntimeControlFake.configure(%{start_result: {:error, :offline}})

    assert {:error,
            %Error{
              code: :apply_failed,
              details: %{"start" => "failed", "stop" => "ok"}
            }} = Runtime.dispatch("server.runtime.services.restart", %{"service" => "dns"})

    assert [stop: :dns, start: :dns] = ServerRuntimeControlFake.take_calls()
  end

  test "restart stops and then starts the same allowlisted service" do
    assert {:ok, %{"service" => "dns", "state" => "running"}} =
             Runtime.dispatch("server.runtime.services.restart", %{"service" => "dns"})

    assert [stop: :dns, start: :dns] = ServerRuntimeControlFake.take_calls()
  end

  test "a stale dispatcher revision rejects before any ServiceManager mutation" do
    Application.put_env(:yellow_dog, Dispatcher, adapters: %{runtime: Runtime})

    assert {:ok, revision} =
             Revision.calculate(%{"service" => "dns", "state" => "running"})

    assert {:error, %Error{code: :conflict}} =
             Control.dispatch(
               envelope("server.runtime.services.stop", %{"service" => "dns"},
                 expected_revision: String.duplicate("a", 64)
               )
             )

    assert revision != String.duplicate("a", 64)
    assert [] = ServerRuntimeControlFake.take_calls()
  end

  defp envelope(operation, payload, overrides) do
    {:ok, payload_digest} = YellowDog.Sync.Digest.calculate(payload)

    %Envelope{
      protocol_version: 1,
      request_id: Keyword.get(overrides, :request_id, @request_id),
      target_type: :server,
      target_id: "server-runtime-test",
      operation: operation,
      idempotency_key: Keyword.get(overrides, :idempotency_key, @idempotency_key),
      payload: payload,
      payload_digest: payload_digest,
      expected_revision: Keyword.get(overrides, :expected_revision),
      config_version: nil,
      sent_at: @sent_at
    }
  end

  defp restore_env(module, nil), do: Application.delete_env(:yellow_dog, module)
  defp restore_env(module, config), do: Application.put_env(:yellow_dog, module, config)
end
