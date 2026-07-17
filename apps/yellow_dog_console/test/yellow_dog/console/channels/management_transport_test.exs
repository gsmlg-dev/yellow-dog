defmodule YellowDog.Console.ManagementTransportTest do
  use ExUnit.Case, async: false

  import Phoenix.ChannelTest

  alias YellowDog.Console.ManagementTransport
  alias YellowDog.Console.ServerChannel
  alias YellowDog.Console.ServerConnections
  alias YellowDog.Console.ServerSocket
  alias YellowDog.ManagementCore
  alias YellowDog.Sync.Digest
  alias YellowDog.Sync.Envelope
  alias YellowDog.Sync.Error
  alias YellowDog.Sync.Identity
  alias YellowDog.Sync.Message

  alias Message.{
    Command,
    ConfigDelivery,
    Hello,
    Query,
    Result,
    Status
  }

  @endpoint YellowDog.Console.Endpoint
  @observed_at ~U[2026-07-18 08:30:00Z]
  @digest String.duplicate("a", 64)

  setup do
    :ok = ServerConnections.reset()
    on_exit(fn -> ServerConnections.reset() end)
    :ok
  end

  test "connected? matches only an active concrete Server connection" do
    server_id = unique_id("connected")
    socket = join_registered(server_id)

    refute ManagementTransport.connected?(:server, server_id)
    refute ManagementTransport.connected?(:netman, server_id)
    refute ManagementTransport.connected?(:server, "")

    activate(socket, server_id)
    assert ManagementTransport.connected?(:server, server_id)
  end

  test "request pushes exact canonical Query and Command wrappers on only sync" do
    server_id = unique_id("outgoing")
    socket = join_registered(server_id)
    activate(socket, server_id)

    for envelope <- [query_envelope(server_id), command_envelope(server_id)] do
      task = Task.async(fn -> ManagementTransport.request(envelope, 1_000) end)

      assert_push "sync",
                  %{"message" => encoded, "publication_sequence" => nil} = outbound

      assert map_size(outbound) == 2
      assert {:ok, decoded} = Message.decode(encoded)

      expected_module =
        if envelope.operation == "server.runtime.services.list", do: Query, else: Command

      assert %{__struct__: ^expected_module, envelope: ^envelope} = decoded

      ref = push(socket, "sync", payload(result(envelope, result_value(envelope))))
      assert_reply ref, :ok, %{"accepted" => true}
      assert {:ok, result_value(envelope)} == Task.await(task)
    end
  end

  test "correlates out-of-order Results and ignores duplicate and wrong-operation replies" do
    server_id = unique_id("correlation")
    socket = join_registered(server_id)
    activate(socket, server_id)
    first = query_envelope(server_id)
    second = command_envelope(server_id)

    first_task = Task.async(fn -> ManagementTransport.request(first, 1_000) end)
    second_task = Task.async(fn -> ManagementTransport.request(second, 1_000) end)
    assert_push "sync", _
    assert_push "sync", _

    wrong = %{
      result(second, result_value(second))
      | request_id: first.request_id
    }

    wrong_ref = push(socket, "sync", payload(wrong))
    assert_reply wrong_ref, :ok, %{"accepted" => true}
    refute Task.yield(first_task, 20)

    wrong_target = %Result{
      request_id: first.request_id,
      target_type: :netman,
      operation: "netman.runtime.capabilities.get",
      value: nil,
      error: Error.new(:internal, "runtime failed", %{})
    }

    wrong_target_ref = push(socket, "sync", payload(wrong_target))
    assert_reply wrong_target_ref, :ok, %{"accepted" => true}
    refute Task.yield(first_task, 20)

    second_ref = push(socket, "sync", payload(result(second, result_value(second))))
    assert_reply second_ref, :ok, %{"accepted" => true}
    assert {:ok, result_value(second)} == Task.await(second_task)

    first_ref = push(socket, "sync", payload(result(first, result_value(first))))
    assert_reply first_ref, :ok, %{"accepted" => true}
    assert {:ok, result_value(first)} == Task.await(first_task)

    duplicate_ref = push(socket, "sync", payload(result(first, result_value(first))))
    assert_reply duplicate_ref, :ok, %{"accepted" => true}
  end

  test "returns a fully validated typed Result error" do
    server_id = unique_id("result-error")
    socket = join_registered(server_id)
    activate(socket, server_id)
    envelope = command_envelope(server_id)
    result_error = Error.new(:apply_failed, "service start failed", %{"service" => "dns"})
    task = Task.async(fn -> ManagementTransport.request(envelope, 1_000) end)
    assert_push "sync", _

    result = %Result{
      request_id: envelope.request_id,
      target_type: :server,
      operation: envelope.operation,
      value: nil,
      error: result_error
    }

    ref = push(socket, "sync", payload(result))
    assert_reply ref, :ok, %{"accepted" => true}
    assert {:error, ^result_error} = Task.await(task)
  end

  test "returns typed timeout and ignores a late Result" do
    server_id = unique_id("timeout")
    socket = join_registered(server_id)
    activate(socket, server_id)
    envelope = query_envelope(server_id)

    task = Task.async(fn -> ManagementTransport.request(envelope, 20) end)
    assert_push "sync", _
    assert {:error, %Error{code: :timeout, details: %{}}} = Task.await(task)

    late_ref = push(socket, "sync", payload(result(envelope, result_value(envelope))))
    assert_reply late_ref, :ok, %{"accepted" => true}
  end

  test "disconnect and replacement clear pending requests with not_connected" do
    trap_channel_exits()
    server_id = unique_id("disconnect")
    first = join_registered(server_id)
    activate(first, server_id)

    disconnected = query_envelope(server_id)
    disconnected_task = Task.async(fn -> ManagementTransport.request(disconnected, 1_000) end)
    assert_push "sync", _
    leave_ref = leave(first)
    assert_reply leave_ref, :ok

    assert {:error, %Error{code: :not_connected, details: %{}}} =
             Task.await(disconnected_task)

    second = join(server_id)
    activate(second, server_id)
    replaced = query_envelope(server_id)
    replaced_task = Task.async(fn -> ManagementTransport.request(replaced, 1_000) end)
    assert_push "sync", _

    third = join(server_id)
    activate(third, server_id)

    assert {:error, %Error{code: :not_connected, details: %{}}} =
             Task.await(replaced_task)

    stale_ref = push(second, "sync", payload(result(replaced, result_value(replaced))))
    refute_receive %Phoenix.Socket.Reply{ref: ^stale_ref}, 50
  end

  test "bounds pending requests at 128 per concrete server" do
    server_id = unique_id("pending-bound")
    socket = join_registered(server_id)
    activate(socket, server_id)

    tasks =
      for _index <- 1..128 do
        envelope = query_envelope(server_id)
        task = Task.async(fn -> ManagementTransport.request(envelope, 2_000) end)
        assert_push "sync", _
        task
      end

    assert {:error, %Error{code: :internal, details: %{}}} =
             ManagementTransport.request(query_envelope(server_id), 100)

    leave_ref = leave(socket)
    assert_reply leave_ref, :ok

    for task <- tasks do
      assert {:error, %Error{code: :not_connected, details: %{}}} = Task.await(task)
    end
  end

  test "deliver_config pushes exact ConfigDelivery and returns after handoff" do
    server_id = unique_id("config")
    socket = join_registered(server_id)
    activate(socket, server_id)
    envelope = config_envelope(server_id)

    assert :ok = ManagementTransport.deliver_config(envelope)

    assert_push "sync", %{"message" => encoded, "publication_sequence" => nil} = outbound
    assert map_size(outbound) == 2
    assert {:ok, %ConfigDelivery{envelope: ^envelope}} = Message.decode(encoded)
  end

  test "transport fails closed for invalid targets, timeouts, and registry unavailability" do
    envelope = query_envelope(unique_id("not-connected"))

    assert {:error, %Error{code: :not_connected}} =
             ManagementTransport.request(envelope, 10)

    assert {:error, %Error{code: :invalid}} =
             ManagementTransport.request(envelope, 0)

    assert {:error, %Error{code: :not_connected}} =
             ManagementTransport.deliver_config(config_envelope(envelope.target_id))

    pid = Process.whereis(ServerConnections)
    :ok = Supervisor.terminate_child(YellowDog.Console.Supervisor, ServerConnections)

    refute ManagementTransport.connected?(:server, envelope.target_id)

    assert {:error, %Error{code: :not_connected}} =
             ManagementTransport.request(envelope, 10)

    assert {:ok, restarted} =
             Supervisor.restart_child(YellowDog.Console.Supervisor, ServerConnections)

    refute restarted == pid
  end

  test "production transport and channel retain no direct Sync imports" do
    modules = [ManagementTransport, ServerChannel, ServerChannel.SyncCodec]

    sync_imports =
      Enum.flat_map(modules, fn module ->
        {:ok, {^module, [imports: imports]}} =
          module
          |> :code.which()
          |> :beam_lib.chunks([:imports])

        Enum.filter(imports, fn {imported_module, _function, _arity} ->
          imported_module
          |> Atom.to_string()
          |> String.starts_with?("Elixir.YellowDog.Sync")
        end)
      end)

    assert sync_imports == []
  end

  defp join_registered(server_id) do
    register_server(server_id)
    join(server_id)
  end

  defp join(server_id) do
    assert {:ok, %{}, socket} =
             socket(ServerSocket, nil, %{server_id: server_id})
             |> subscribe_and_join(ServerChannel, "server:control:#{server_id}")

    socket
  end

  defp activate(socket, server_id) do
    hello_ref = push(socket, "sync", payload(hello(server_id)))
    assert_reply hello_ref, :ok, %{"accepted" => true}
    status_ref = push(socket, "sync", payload(status(server_id)))
    assert_reply status_ref, :ok, %{"accepted" => true}
  end

  defp hello(server_id) do
    %Hello{
      identity: %Identity.Server{
        id: server_id,
        name: "Server #{server_id}",
        version: "1.0.0",
        profile: "dns_only",
        capabilities: ["runtime.services"],
        config_revision: @digest
      }
    }
  end

  defp status(server_id) do
    %Status{
      target_type: :server,
      target_id: server_id,
      state: :online,
      details: %{},
      observed_at: @observed_at
    }
  end

  defp query_envelope(server_id) do
    envelope(server_id, "server.runtime.services.list", %{})
  end

  defp command_envelope(server_id) do
    envelope(server_id, "server.runtime.services.start", %{"service" => "dns"})
  end

  defp config_envelope(server_id) do
    envelope(
      server_id,
      "server.settings.update",
      %{
        "service" => "dns",
        "entries" => [
          %{"key" => "listen", "value" => %{"type" => "string", "value" => "192.0.2.53"}}
        ]
      },
      1
    )
  end

  defp envelope(server_id, operation, payload, config_version \\ nil) do
    {:ok, digest} = Digest.calculate(payload)

    %Envelope{
      protocol_version: 1,
      request_id: uuid(),
      target_type: :server,
      target_id: server_id,
      operation: operation,
      idempotency_key: uuid(),
      payload: payload,
      payload_digest: digest,
      expected_revision: nil,
      config_version: config_version,
      sent_at: DateTime.utc_now()
    }
  end

  defp result(envelope, value) do
    %Result{
      request_id: envelope.request_id,
      target_type: envelope.target_type,
      operation: envelope.operation,
      value: value,
      error: nil
    }
  end

  defp result_value(%{operation: "server.runtime.services.list"}) do
    %{
      "items" => [%{"service" => "dns", "state" => "running"}],
      "revision" => @digest,
      "observed_at" => DateTime.to_iso8601(@observed_at)
    }
  end

  defp result_value(%{operation: "server.runtime.services.start"}) do
    %{"service" => "dns", "state" => "running"}
  end

  defp payload(message) do
    {:ok, encoded} = Message.encode(message)
    %{"message" => encoded, "publication_sequence" => nil}
  end

  defp register_server(server_id) do
    assert {:ok, _server} =
             ManagementCore.register_server(%{id: server_id, profile: :dns_only})
  end

  defp trap_channel_exits do
    previous = Process.flag(:trap_exit, true)
    on_exit(fn -> Process.flag(:trap_exit, previous) end)
  end

  defp unique_id(prefix),
    do: "#{prefix}-#{Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)}"

  defp uuid do
    <<prefix::binary-size(6), version, middle, variant, suffix::binary-size(7)>> =
      :crypto.strong_rand_bytes(16)

    bytes =
      <<prefix::binary, Bitwise.band(version, 0x0F) + 0x40, middle,
        Bitwise.band(variant, 0x3F) + 0x80, suffix::binary>>

    Base.encode16(bytes, case: :lower)
    |> then(fn value ->
      binary_part(value, 0, 8) <>
        "-" <>
        binary_part(value, 8, 4) <>
        "-" <>
        binary_part(value, 12, 4) <>
        "-" <>
        binary_part(value, 16, 4) <> "-" <> binary_part(value, 20, 12)
    end)
  end
end
