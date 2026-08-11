defmodule YellowDog.Console.ServerChannelTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Phoenix.ChannelTest

  alias YellowDog.Console.ServerChannel
  alias YellowDog.Console.ServerConnections
  alias YellowDog.Console.ServerSocket
  alias YellowDog.ManagementCore
  alias YellowDog.Sync.Identity
  alias YellowDog.Sync.Message

  alias Message.{
    ConfigDelivery,
    ConfigState,
    Event,
    Heartbeat,
    Hello,
    Journal,
    Result,
    Status
  }

  @endpoint YellowDog.Console.Endpoint
  @observed_at ~U[2026-07-17 08:30:00Z]
  @request_id "7f12c5d1-6a5d-4b2e-9a75-4a6d5d8f18c0"
  @event_id "39c5b8cc-fc32-40c5-9517-3d5c0a423df4"
  @digest String.duplicate("a", 64)

  setup do
    :ok = ServerConnections.reset()
    on_exit(fn -> ServerConnections.reset() end)
    :ok
  end

  test "binds an authenticated server to exactly its concrete control topic" do
    server_id = unique_id("topic")
    register_server(server_id)
    socket = channel_socket(server_id)

    assert {:ok, %{}, joined} =
             subscribe_and_join(socket, ServerChannel, "server:control:#{server_id}")

    assert joined.assigns.server_id == server_id

    assert {:error, %{"error" => %{"code" => "invalid"}}} =
             subscribe_and_join(socket, ServerChannel, "server:control:other")

    assert {:error, %{"error" => %{"code" => "invalid"}}} =
             subscribe_and_join(socket, ServerChannel, "server:control")
  end

  test "activates only after canonical Hello, matching Status, and Journal" do
    server_id = unique_id("handshake")
    socket = join_registered(server_id)

    ref = push(socket, "sync", payload(status(server_id)))
    assert_reply ref, :error, %{"error" => %{"code" => "not_connected"}}
    refute ServerConnections.connected?(server_id)

    ref = push(socket, "sync", payload(hello(server_id)))
    assert_reply ref, :ok, %{"accepted" => true}
    refute ServerConnections.connected?(server_id)

    ref = push(socket, "sync", payload(status(server_id)))
    assert_reply ref, :ok, %{"accepted" => true}
    refute ServerConnections.connected?(server_id)

    ref = push(socket, "sync", payload(journal(server_id)))
    assert_reply ref, :ok, %{"accepted" => true}
    assert ServerConnections.connected?(server_id)

    assert {:ok, %{identity: %{id: ^server_id}, status: %{target_id: ^server_id}}} =
             ServerConnections.get(server_id)
  end

  test "rejects ConfigState before Journal activation without side effects" do
    server_id = unique_id("pre-active-config")
    register_server(server_id)
    assert {:ok, desired} = publish_config(server_id)
    socket = join(server_id)

    ref = push(socket, "sync", payload(config_state(desired), 1))
    assert_reply ref, :error, %{"error" => %{"code" => "not_connected"}}

    assert {:ok, unchanged} =
             ManagementCore.get_server_config_version(server_id, desired.version)

    assert unchanged.state == :desired
  end

  test "keeps the active channel until a replacement submits a valid Journal" do
    trap_channel_exits()
    server_id = unique_id("channel-replacement")
    first = join_registered(server_id)
    activate(first, server_id)
    first_pid = first.channel_pid

    second = join(server_id)
    assert {:ok, %{channel_pid: ^first_pid}} = ServerConnections.get(server_id)

    ref = push(second, "sync", payload(hello(server_id, "replacement")))
    assert_reply ref, :ok, %{"accepted" => true}
    assert {:ok, %{channel_pid: ^first_pid}} = ServerConnections.get(server_id)

    ref = push(second, "sync", payload(status(server_id, "replacement")))
    assert_reply ref, :ok, %{"accepted" => true}
    assert {:ok, %{channel_pid: ^first_pid}} = ServerConnections.get(server_id)

    monitor = Process.monitor(first_pid)
    invalid_ref = push(second, "sync", payload(conflicting_journal(server_id)))
    assert_reply invalid_ref, :error, %{"error" => %{"code" => "invalid"}}
    assert {:ok, %{channel_pid: ^first_pid}} = ServerConnections.get(server_id)
    refute_receive {:DOWN, ^monitor, :process, ^first_pid, _reason}, 20

    ref = push(second, "sync", payload(journal(server_id)))
    assert_reply ref, :ok, %{"accepted" => true}
    assert_receive {:DOWN, ^monitor, :process, ^first_pid, _reason}
    assert_receive {:EXIT, ^first_pid, {:shutdown, :replaced}}

    assert {:ok, %{channel_pid: second_pid}} = ServerConnections.get(server_id)
    assert second_pid == second.channel_pid
  end

  test "requires the sole sync event and exact payload keys" do
    server_id = unique_id("framing")
    socket = join_registered(server_id)

    ref = push(socket, "status", payload(hello(server_id)))
    assert_reply ref, :error, %{"error" => %{"code" => "invalid"}}

    encoded = encode(hello(server_id))

    for invalid <- [
          %{"message" => encoded},
          %{"publication_sequence" => nil},
          %{"message" => encoded, "publication_sequence" => nil, "extra" => true}
        ] do
      ref = push(socket, "sync", invalid)
      assert_reply ref, :error, %{"error" => %{"code" => "invalid"}}
    end
  end

  test "rejects malformed, noncanonical, cross-ID, and invalid sequence publications" do
    server_id = unique_id("canonical")
    other_id = unique_id("cross-id")
    socket = join_registered(server_id)

    for invalid_message <- ["{", " " <> encode(hello(server_id))] do
      ref =
        push(socket, "sync", %{
          "message" => invalid_message,
          "publication_sequence" => nil
        })

      assert_reply ref, :error, %{"error" => %{"code" => "invalid"}}
    end

    ref = push(socket, "sync", payload(hello(other_id)))
    assert_reply ref, :error, %{"error" => %{"code" => "invalid"}}

    ref =
      push(socket, "sync", %{
        "message" => encode(hello(server_id)),
        "publication_sequence" => 1
      })

    assert_reply ref, :error, %{"error" => %{"code" => "invalid"}}

    ref = push(socket, "sync", payload(hello(server_id)))
    assert_reply ref, :ok, %{"accepted" => true}
    ref = push(socket, "sync", payload(status(server_id)))
    assert_reply ref, :ok, %{"accepted" => true}

    for sequence <- [nil, 0, -1] do
      invalid = %{
        "message" => encode(config_state_message(server_id)),
        "publication_sequence" => sequence
      }

      ref = push(socket, "sync", invalid)
      assert_reply ref, :error, %{"error" => %{"code" => "invalid"}}
    end
  end

  test "Journal reconciles runtime before accepted reply and Heartbeat touches presence" do
    server_id = unique_id("journal")
    socket = join_registered(server_id)
    activate(socket, server_id)

    assert {:ok, before_touch} = ServerConnections.get(server_id)
    Process.sleep(2)

    ref = push(socket, "sync", payload(heartbeat(server_id)))
    assert_reply ref, :ok, %{"accepted" => true}
    assert {:ok, after_touch} = ServerConnections.get(server_id)
    assert DateTime.compare(after_touch.last_seen_at, before_touch.last_seen_at) in [:gt, :eq]

    ref = push(socket, "sync", payload(journal(server_id)))
    assert_reply ref, :ok, %{"accepted" => true}
    assert {:ok, %{status: :online}} = ManagementCore.get_server(server_id)
  end

  test "queued Journal from a replaced channel cannot reconcile or deliver pending config" do
    trap_channel_exits()
    server_id = unique_id("stale-journal")
    register_server(server_id)
    assert {:ok, _first} = publish_config(server_id, "192.0.2.51")
    assert {:ok, latest} = publish_config(server_id, "192.0.2.52")
    old = join(server_id)
    activate(old, server_id)
    assert_push "sync", %{"message" => _initial_delivery, "publication_sequence" => nil}
    suspend_channel(old)

    old_ref = push(old, "sync", payload(journal(server_id)))
    replacement = join(server_id)
    activate(replacement, server_id)
    assert_push "sync", %{"message" => _replacement_delivery, "publication_sequence" => nil}
    :ok = :sys.resume(old.channel_pid)

    assert_reply old_ref, :error, %{"error" => %{"code" => "not_connected"}}
    assert {:ok, %{status: :online}} = ManagementCore.get_server(server_id)
    assert {:ok, unchanged} = ManagementCore.get_server_config_version(server_id, latest.version)
    assert unchanged.state == :desired
    refute_push "sync", _, 50
  end

  test "queued ConfigState from a replaced channel cannot create a durable receipt" do
    trap_channel_exits()
    server_id = unique_id("stale-config-state")
    register_server(server_id)
    assert {:ok, desired} = publish_config(server_id)
    old = join(server_id)
    activate(old, server_id)
    suspend_channel(old)

    old_ref = push(old, "sync", payload(config_state(desired), 1))
    replacement = join(server_id)
    activate(replacement, server_id)
    :ok = :sys.resume(old.channel_pid)

    assert_reply old_ref, :error, %{"error" => %{"code" => "not_connected"}}
    assert {:ok, unchanged} = ManagementCore.get_server_config_version(server_id, desired.version)
    assert unchanged.state == :desired
  end

  test "Journal reconnect delivers exactly the latest offline config version" do
    server_id = unique_id("latest-config")
    register_server(server_id)
    assert {:ok, first} = publish_config(server_id, "192.0.2.61")
    assert {:ok, latest} = publish_config(server_id, "192.0.2.62")
    socket = join(server_id)
    activate(socket, server_id)

    assert_push "sync", %{"message" => encoded, "publication_sequence" => nil}
    assert {:ok, %ConfigDelivery{envelope: envelope}} = Message.decode(encoded)
    assert envelope.target_type == :server
    assert envelope.target_id == server_id
    assert envelope.operation == latest.operation
    assert envelope.payload == latest.payload
    assert envelope.payload_digest == latest.digest
    assert envelope.expected_revision == latest.expected_revision
    assert envelope.config_version == latest.version
    refute envelope.config_version == first.version
    refute_push "sync", _, 50

    assert {:ok, unchanged} = ManagementCore.get_server_config_version(server_id, latest.version)
    assert unchanged.state == :desired
  end

  test "incoming canonical payload content is not logged" do
    server_id = unique_id("payload-log")
    marker = "canonical-payload-marker-#{System.unique_integer([:positive])}"
    socket = join_registered(server_id)

    assert ServerChannel.__socket__(:private).log_handle_in == false

    log =
      capture_log([level: :debug], fn ->
        ref = push(socket, "sync", payload(hello(server_id, marker)))
        assert_reply ref, :ok, %{"accepted" => true}
      end)

    refute log =~ marker
  end

  test "ConfigState returns the durable direct receipt and exact replay reply" do
    server_id = unique_id("receipt")
    register_server(server_id)
    assert {:ok, desired} = publish_config(server_id)
    socket = join(server_id)
    activate(socket, server_id)
    publication = payload(config_state(desired), 1)

    ref = push(socket, "sync", publication)

    assert_reply ref,
                 :ok,
                 %{
                   "target_type" => "server",
                   "target_id" => ^server_id,
                   "publication_sequence" => 1,
                   "state_revision" => 1
                 } = receipt

    refute Map.has_key?(receipt, "accepted")

    replay_ref = push(socket, "sync", publication)
    assert_reply replay_ref, :ok, ^receipt
  end

  test "accepts ignorable valid Result and rejects unsupported Event wrappers" do
    server_id = unique_id("unsupported")
    socket = join_registered(server_id)
    activate(socket, server_id)

    ref = push(socket, "sync", payload(result()))
    assert_reply ref, :ok, %{"accepted" => true}

    ref = push(socket, "sync", payload(event(server_id)))
    assert_reply ref, :error, %{"error" => %{"code" => "unsupported"}}
  end

  test "persists periodic Status only from the active channel before acknowledgement" do
    server_id = unique_id("periodic-status")
    socket = join_registered(server_id)
    activate(socket, server_id)
    periodic = %{status(server_id, "periodic") | state: :offline}

    ref = push(socket, "sync", payload(periodic))
    assert_reply ref, :ok, %{"accepted" => true}

    assert {:ok, %{status: :offline}} = ManagementCore.get_server(server_id)
    assert {:ok, %{status: %{state: :offline}}} = ServerConnections.get(server_id)
  end

  test "candidate disconnect does not evict active, while active disconnect marks offline" do
    trap_channel_exits()
    server_id = unique_id("disconnect")
    active = join_registered(server_id)
    activate(active, server_id)
    active_pid = active.channel_pid

    candidate = join(server_id)
    candidate_ref = leave(candidate)
    assert_reply candidate_ref, :ok

    assert {:ok, %{channel_pid: ^active_pid, connected?: true}} =
             ServerConnections.get(server_id)

    active_ref = leave(active)
    assert_reply active_ref, :ok

    eventually(fn ->
      refute ServerConnections.connected?(server_id)
      assert {:ok, %{status: :offline}} = ManagementCore.get_server(server_id)
    end)
  end

  test "production channel BEAM has no direct YellowDog.Sync imports" do
    modules = [ServerChannel, ServerChannel.SyncCodec]

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
             channel_socket(server_id)
             |> subscribe_and_join(ServerChannel, "server:control:#{server_id}")

    socket
  end

  defp channel_socket(server_id) do
    socket(ServerSocket, nil, %{server_id: server_id})
  end

  defp activate(socket, server_id) do
    ref = push(socket, "sync", payload(hello(server_id)))
    assert_reply ref, :ok, %{"accepted" => true}

    ref = push(socket, "sync", payload(status(server_id)))
    assert_reply ref, :ok, %{"accepted" => true}

    ref = push(socket, "sync", payload(journal(server_id)))
    assert_reply ref, :ok, %{"accepted" => true}
  end

  defp hello(server_id, name \\ "primary") do
    %Hello{
      identity: %Identity.Server{
        id: server_id,
        name: "Server #{name}",
        version: "1.0.0",
        profile: "dns_only",
        capabilities: ["runtime.services"],
        config_revision: @digest
      }
    }
  end

  defp status(server_id, marker \\ "primary") do
    %Status{
      target_type: :server,
      target_id: server_id,
      state: :online,
      details: %{"marker" => marker},
      observed_at: @observed_at
    }
  end

  defp heartbeat(server_id) do
    %Heartbeat{target_type: :server, target_id: server_id, observed_at: @observed_at}
  end

  defp journal(server_id) do
    %Journal{target_type: :server, target_id: server_id, entries: []}
  end

  defp conflicting_journal(server_id) do
    entry = %{
      "request_id" => @request_id,
      "operation" => "server.runtime.services.start",
      "status" => "unknown",
      "result" => nil,
      "error" => nil
    }

    completed = %{
      entry
      | "status" => "completed",
        "result" => %{"service" => "dns", "state" => "running"}
    }

    %Journal{target_type: :server, target_id: server_id, entries: [entry, completed]}
  end

  defp event(server_id) do
    %Event{
      target_type: :server,
      target_id: server_id,
      event_id: @event_id,
      name: "runtime.service.started",
      payload: %{"service" => "dns"},
      observed_at: @observed_at
    }
  end

  defp result do
    %Result{
      request_id: @request_id,
      target_type: :server,
      operation: "server.runtime.services.start",
      value: %{"service" => "dns", "state" => "running"},
      error: nil
    }
  end

  defp publish_config(server_id, listen_address \\ "192.0.2.53") do
    ManagementCore.publish_server_config(server_id, %{
      operation: "server.settings.update",
      payload: %{
        "service" => "dns",
        "entries" => [
          %{
            "key" => "listen",
            "value" => %{"type" => "string", "value" => listen_address}
          }
        ]
      },
      expected_revision: nil
    })
  end

  defp config_state(version) do
    %ConfigState{
      target_type: :server,
      target_id: version.target_id,
      operation: version.operation,
      state: :delivered,
      version: version.version,
      digest: version.digest,
      applied_revision: nil,
      previous_version: nil,
      previous_revision: nil,
      failure: nil,
      rollback: nil,
      observed_at: @observed_at
    }
  end

  defp config_state_message(server_id) do
    %ConfigState{
      target_type: :server,
      target_id: server_id,
      operation: "server.settings.update",
      state: :delivered,
      version: 1,
      digest: @digest,
      applied_revision: nil,
      previous_version: nil,
      previous_revision: nil,
      failure: nil,
      rollback: nil,
      observed_at: @observed_at
    }
  end

  defp payload(message, publication_sequence \\ nil) do
    %{
      "message" => encode(message),
      "publication_sequence" => publication_sequence
    }
  end

  defp encode(message) do
    assert {:ok, encoded} = Message.encode(message)
    encoded
  end

  defp register_server(server_id) do
    assert {:ok, _server} =
             ManagementCore.register_server(%{id: server_id, profile: :dns_only})
  end

  defp trap_channel_exits do
    previous = Process.flag(:trap_exit, true)
    on_exit(fn -> Process.flag(:trap_exit, previous) end)
  end

  defp suspend_channel(socket) do
    :ok = :sys.suspend(socket.channel_pid)

    on_exit(fn ->
      if Process.alive?(socket.channel_pid) do
        :sys.resume(socket.channel_pid)
      end
    end)
  end

  defp eventually(assertion, attempts \\ 20)
  defp eventually(assertion, 0), do: assertion.()

  defp eventually(assertion, attempts) do
    assertion.()
  rescue
    ExUnit.AssertionError ->
      Process.sleep(10)
      eventually(assertion, attempts - 1)
  end

  defp unique_id(prefix),
    do: "#{prefix}-#{Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)}"
end
