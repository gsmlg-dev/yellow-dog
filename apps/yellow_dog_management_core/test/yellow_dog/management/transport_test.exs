defmodule YellowDog.Management.TransportTest do
  use ExUnit.Case, async: false

  alias YellowDog.Management.Commands
  alias YellowDog.Management.DisconnectedTransport
  alias YellowDog.Management.FakeTransport
  alias YellowDog.ManagementCore
  alias YellowDog.Sync.Digest
  alias YellowDog.Sync.Envelope
  alias YellowDog.Sync.Error
  alias YellowDog.Sync.Operation

  @uuid_v4 ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
  @key "77777777-7777-4777-8777-777777777777"

  setup do
    previous_env =
      Map.new([:data_dir, :transport_module, :request_timeout], fn key ->
        {key, Application.fetch_env(:yellow_dog_management_core, key)}
      end)

    data_dir =
      Path.join(System.tmp_dir!(), "yellow-dog-transport-#{System.unique_integer([:positive])}")

    Application.put_env(:yellow_dog_management_core, :data_dir, data_dir)
    Application.put_env(:yellow_dog_management_core, :transport_module, FakeTransport)
    Application.put_env(:yellow_dog_management_core, :request_timeout, 123)
    restart_application()
    start_supervised!(FakeTransport)

    on_exit(fn ->
      Application.stop(:yellow_dog_management_core)
      Enum.each(previous_env, fn {key, value} -> restore_env(key, value) end)
      {:ok, _apps} = Application.ensure_all_started(:yellow_dog_management_core)
      File.rm_rf(data_dir)
    end)

    :ok
  end

  test "disconnected transport is Phoenix-free and returns typed errors" do
    refute DisconnectedTransport.connected?(:server, "server-1")

    envelope = query_envelope("server-1")
    assert_error(DisconnectedTransport.request(envelope, 5_000), :not_connected)
    assert_error(DisconnectedTransport.deliver_config(envelope), :not_connected)

    refute transport_source() =~ "Phoenix"
  end

  test "facade sends only a validated protocol-v1 envelope with the configured timeout" do
    register_server("server-envelope")
    :ok = FakeTransport.connect(:server, "server-envelope")
    result = %{"capabilities" => ["runtime.services"]}
    :ok = FakeTransport.script([{:ok, result}])

    assert {:ok, ^result} =
             ManagementCore.query_server(
               "server-envelope",
               "runtime.capabilities",
               "server.runtime.capabilities.get",
               %{}
             )

    assert [
             %{
               kind: :query,
               timeout: 123,
               envelope:
                 %Envelope{
                   protocol_version: 1,
                   target_type: :server,
                   target_id: "server-envelope",
                   operation: "server.runtime.capabilities.get",
                   payload: %{},
                   expected_revision: nil,
                   config_version: nil,
                   sent_at: %DateTime{} = sent_at
                 } = envelope
             }
           ] = FakeTransport.recorded()

    assert Regex.match?(@uuid_v4, envelope.request_id)
    assert Regex.match?(@uuid_v4, envelope.idempotency_key)
    assert envelope.idempotency_key != envelope.request_id
    assert sent_at.utc_offset == 0
    assert sent_at.std_offset == 0
    assert :ok = Digest.verify(envelope.payload, envelope.payload_digest)
    assert {:ok, ^envelope} = Operation.validate_envelope(envelope, :query)
  end

  test "unregistered and invalid requests are rejected before transport" do
    assert_error(
      ManagementCore.query_server(
        "server-unknown",
        "runtime.capabilities",
        "server.runtime.capabilities.get",
        %{}
      ),
      :not_found
    )

    register_server("server-invalid")
    :ok = FakeTransport.connect(:server, "server-invalid")

    assert_error(
      ManagementCore.query_server(
        "server-invalid",
        "runtime.capabilities",
        "server.runtime.capabilities.get",
        %{"path" => "/tmp/runtime"}
      ),
      :invalid
    )

    assert_error(
      ManagementCore.command_server(
        "server-invalid",
        "server.runtime.unknown",
        %{},
        nil,
        @key
      ),
      :invalid
    )

    assert FakeTransport.recorded() == []
  end

  test "invalid snapshot domains are rejected before transport" do
    register_server("server-invalid-domain")
    :ok = FakeTransport.connect(:server, "server-invalid-domain")

    assert_error(
      ManagementCore.query_server(
        "server-invalid-domain",
        "runtime/services",
        "server.runtime.capabilities.get",
        %{}
      ),
      :invalid
    )

    assert FakeTransport.recorded() == []
  end

  test "transport request executes in the facade caller rather than Commands" do
    register_server("server-caller")
    :ok = FakeTransport.connect(:server, "server-caller")
    :ok = FakeTransport.script([{:defer, self(), :caller}])

    task =
      Task.async(fn ->
        ManagementCore.command_server(
          "server-caller",
          "server.runtime.services.start",
          %{"service" => "dns"},
          nil,
          @key
        )
      end)

    assert_receive {:fake_transport_deferred, :caller, _envelope}
    assert [%{caller: caller}] = FakeTransport.recorded()
    assert caller == task.pid
    refute caller == Process.whereis(Commands)

    result = %{"service" => "dns", "state" => "running"}
    :ok = FakeTransport.reply(:caller, {:ok, result})
    assert Task.await(task) == {:ok, result}
  end

  defp query_envelope(target_id) do
    payload = %{}
    {:ok, digest} = Digest.calculate(payload)

    %Envelope{
      protocol_version: 1,
      request_id: "88888888-8888-4888-8888-888888888888",
      target_type: :server,
      target_id: target_id,
      operation: "server.runtime.capabilities.get",
      idempotency_key: "99999999-9999-4999-8999-999999999999",
      payload: payload,
      payload_digest: digest,
      expected_revision: nil,
      config_version: nil,
      sent_at: ~U[2026-07-16 09:30:00Z]
    }
  end

  defp register_server(id) do
    assert {:ok, _server} = ManagementCore.register_server(%{id: id, profile: :dns_only})
  end

  defp assert_error(result, code) do
    assert {:error, %Error{code: ^code}} = result
  end

  defp transport_source do
    path =
      Path.join([__DIR__, "..", "..", "..", "lib", "yellow_dog", "management", "transport.ex"])

    File.read!(path)
  end

  defp restart_application do
    :ok = Application.stop(:yellow_dog_management_core)
    {:ok, _apps} = Application.ensure_all_started(:yellow_dog_management_core)
  end

  defp restore_env(key, {:ok, value}),
    do: Application.put_env(:yellow_dog_management_core, key, value)

  defp restore_env(key, :error), do: Application.delete_env(:yellow_dog_management_core, key)
end
