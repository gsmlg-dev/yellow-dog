defmodule YellowDog.Console.NetmanControlChannelTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Phoenix.ChannelTest

  alias YellowDog.Console.NetmanConnections
  alias YellowDog.Console.NetmanControlChannel
  alias YellowDog.Console.NetmanSocket
  alias YellowDog.Management.Netmans
  alias YellowDog.ManagementCore
  alias YellowDog.Sync.Digest
  alias YellowDog.Sync.Envelope
  alias YellowDog.Sync.Identity
  alias YellowDog.Sync.Message

  alias Message.{ConfigDelivery, ConfigState, Event, Heartbeat, Hello, Journal, Result, Status}

  @endpoint YellowDog.Console.Endpoint
  @observed_at ~U[2026-08-11 08:30:00Z]
  @request_id "7f12c5d1-6a5d-4b2e-9a75-4a6d5d8f18c0"
  @event_id "39c5b8cc-fc32-40c5-9517-3d5c0a423df4"
  @digest String.duplicate("a", 64)

  setup do
    :ok = NetmanConnections.reset()
    on_exit(fn -> NetmanConnections.reset() end)
    :ok
  end

  test "binds a typed socket to exactly its concrete control topic" do
    netman_id = unique_id("topic")
    register_netman(netman_id)
    socket = channel_socket(netman_id)

    assert {:ok, %{}, joined} =
             subscribe_and_join(socket, NetmanControlChannel, "netman:control:#{netman_id}")

    assert joined.assigns.netman_id == netman_id

    assert {:error, %{"error" => %{"code" => "invalid"}}} =
             subscribe_and_join(socket, NetmanControlChannel, "netman:control:other")

    assert {:error, %{"error" => %{"code" => "invalid"}}} =
             subscribe_and_join(socket, NetmanControlChannel, "netman:control")
  end

  test "activates only after canonical Netman Hello, matching Status, and Journal" do
    netman_id = unique_id("handshake")
    socket = join_registered(netman_id)

    ref = push(socket, "sync", payload(status(netman_id)))
    assert_reply ref, :error, %{"error" => %{"code" => "not_connected"}}
    refute NetmanConnections.connected?(netman_id)

    ref = push(socket, "sync", payload(hello(netman_id)))
    assert_reply ref, :ok, %{"accepted" => true}
    refute NetmanConnections.connected?(netman_id)

    ref = push(socket, "sync", payload(status(netman_id)))
    assert_reply ref, :ok, %{"accepted" => true}
    refute NetmanConnections.connected?(netman_id)

    ref = push(socket, "sync", payload(journal(netman_id)))
    assert_reply ref, :ok, %{"accepted" => true}
    assert NetmanConnections.connected?(netman_id)

    assert {:ok, %{identity: %{target_type: :netman, id: ^netman_id}}} =
             NetmanConnections.get(netman_id)
  end

  test "rejects ConfigState before Journal activation without side effects" do
    netman_id = unique_id("pre-active-config")
    register_netman(netman_id)
    assert {:ok, desired} = publish_config(netman_id)
    socket = join_registered(netman_id)

    ref = push(socket, "sync", payload(config_state(desired), 1))
    assert_reply ref, :error, %{"error" => %{"code" => "not_connected"}}

    assert {:ok, unchanged} =
             ManagementCore.get_netman_config_version(netman_id, desired.version)

    assert unchanged.state == :desired
  end

  test "requires canonical exact framing and rejects target or identity changes" do
    netman_id = unique_id("canonical")
    other_id = unique_id("other")
    socket = join_registered(netman_id)
    encoded = encode(hello(netman_id))

    for {event, invalid} <- [
          {"status", payload(hello(netman_id))},
          {"sync", %{"message" => encoded}},
          {"sync", %{"message" => encoded, "publication_sequence" => nil, "extra" => true}},
          {"sync", %{"message" => " " <> encoded, "publication_sequence" => nil}},
          {"sync", %{"message" => encoded, "publication_sequence" => 1}}
        ] do
      ref = push(socket, event, invalid)
      assert_reply ref, :error, %{"error" => %{"code" => "invalid"}}
    end

    ref = push(socket, "sync", payload(hello(other_id)))
    assert_reply ref, :error, %{"error" => %{"code" => "invalid"}}

    ref = push(socket, "sync", payload(server_hello(netman_id)))
    assert_reply ref, :error, %{"error" => %{"code" => "invalid"}}

    activate(socket, netman_id)

    ref = push(socket, "sync", payload(hello(netman_id)))
    assert_reply ref, :error, %{"error" => %{"code" => "unsupported"}}
  end

  test "reconciles Journal and persists heartbeat and status before acknowledgement" do
    netman_id = unique_id("runtime")
    socket = join_registered(netman_id)
    activate(socket, netman_id)

    ref = push(socket, "sync", payload(journal(netman_id)))
    assert_reply ref, :ok, %{"accepted" => true}
    assert {:ok, %{status: :online}} = ManagementCore.get_netman(netman_id)

    assert {:ok, before_touch} = NetmanConnections.get(netman_id)
    Process.sleep(2)
    ref = push(socket, "sync", payload(heartbeat(netman_id)))
    assert_reply ref, :ok, %{"accepted" => true}
    assert {:ok, after_touch} = NetmanConnections.get(netman_id)
    assert DateTime.compare(after_touch.last_seen_at, before_touch.last_seen_at) in [:gt, :eq]

    periodic = %{status(netman_id, "periodic") | state: :degraded}
    ref = push(socket, "sync", payload(periodic))
    assert_reply ref, :ok, %{"accepted" => true}
    assert {:ok, %{status: "degraded"}} = ManagementCore.get_netman(netman_id)
  end

  test "preserves stable management error codes when Journal reconciliation fails" do
    netman_id = unique_id("journal-error")
    socket = join_registered(netman_id)
    activate(socket, netman_id)

    assert :ok = Netmans.reset()

    ref = push(socket, "sync", payload(journal(netman_id)))
    assert_reply ref, :error, %{"error" => %{"code" => "not_found"}}
  end

  test "accepts stale Results but explicitly rejects inbound config delivery and events" do
    netman_id = unique_id("unsupported")
    socket = join_registered(netman_id)
    activate(socket, netman_id)

    ref = push(socket, "sync", payload(result()))
    assert_reply ref, :ok, %{"accepted" => true}

    for {unsupported, sequence} <- [
          {config_delivery(netman_id), nil},
          {event(netman_id), nil}
        ] do
      ref = push(socket, "sync", payload(unsupported, sequence))
      assert_reply ref, :error, %{"error" => %{"code" => "unsupported"}}
    end
  end

  test "Journal activation delivers the outstanding offline Netman config exactly once" do
    netman_id = unique_id("offline-config")
    register_netman(netman_id)
    assert {:ok, desired} = publish_config(netman_id, "offline")
    socket = join_registered(netman_id)

    activate(socket, netman_id)

    assert_push "sync", %{"message" => encoded, "publication_sequence" => nil}
    assert {:ok, %ConfigDelivery{envelope: envelope}} = Message.decode(encoded)
    assert envelope.target_type == :netman
    assert envelope.target_id == netman_id
    assert envelope.operation == desired.operation
    assert envelope.payload == desired.payload
    assert envelope.payload_digest == desired.digest
    assert envelope.config_version == desired.version
    refute_push "sync", _, 50
  end

  test "ConfigState returns the durable direct receipt and exact replay reply" do
    netman_id = unique_id("receipt")
    socket = join_registered(netman_id)
    activate(socket, netman_id)
    assert {:ok, desired} = publish_config(netman_id)
    assert_push "sync", %{"message" => _delivery, "publication_sequence" => nil}
    publication = payload(config_state(desired), 1)

    ref = push(socket, "sync", publication)

    assert_reply ref,
                 :ok,
                 %{
                   "target_type" => "netman",
                   "target_id" => ^netman_id,
                   "publication_sequence" => 1,
                   "state_revision" => 1
                 } = receipt

    replay_ref = push(socket, "sync", publication)
    assert_reply replay_ref, :ok, ^receipt
  end

  test "does not log canonical inbound payload content" do
    netman_id = unique_id("payload-log")
    marker = "typed-netman-secret-marker-#{System.unique_integer([:positive])}"
    socket = join_registered(netman_id)

    assert NetmanControlChannel.__socket__(:private).log_handle_in == false

    log =
      capture_log([level: :debug], fn ->
        ref = push(socket, "sync", payload(hello(netman_id, marker)))
        assert_reply ref, :ok, %{"accepted" => true}
      end)

    refute log =~ marker
  end

  defp join_registered(netman_id) do
    register_netman(netman_id)

    assert {:ok, %{}, socket} =
             channel_socket(netman_id)
             |> subscribe_and_join(NetmanControlChannel, "netman:control:#{netman_id}")

    socket
  end

  defp channel_socket(netman_id) do
    socket(NetmanSocket, nil, %{netman_id: netman_id, control_protocol: :typed})
  end

  defp activate(socket, netman_id) do
    ref = push(socket, "sync", payload(hello(netman_id)))
    assert_reply ref, :ok, %{"accepted" => true}

    ref = push(socket, "sync", payload(status(netman_id)))
    assert_reply ref, :ok, %{"accepted" => true}

    ref = push(socket, "sync", payload(journal(netman_id)))
    assert_reply ref, :ok, %{"accepted" => true}
  end

  defp hello(netman_id, name \\ "primary") do
    %Hello{
      identity: %Identity.Netman{
        id: netman_id,
        name: "Netman #{name}",
        version: "1.0.0",
        profile: "vm",
        capabilities: ["runtime.capabilities"],
        config_revision: @digest
      }
    }
  end

  defp server_hello(netman_id) do
    %Hello{
      identity: %Identity.Server{
        id: netman_id,
        name: "Wrong runtime type",
        version: "1.0.0",
        profile: "dns_only",
        capabilities: ["runtime.services"],
        config_revision: @digest
      }
    }
  end

  defp status(netman_id, marker \\ "primary") do
    %Status{
      target_type: :netman,
      target_id: netman_id,
      state: :online,
      details: %{"marker" => marker},
      observed_at: @observed_at
    }
  end

  defp heartbeat(netman_id) do
    %Heartbeat{target_type: :netman, target_id: netman_id, observed_at: @observed_at}
  end

  defp journal(netman_id) do
    %Journal{target_type: :netman, target_id: netman_id, entries: []}
  end

  defp result do
    %Result{
      request_id: @request_id,
      target_type: :netman,
      operation: "netman.runtime.capabilities.get",
      value: %{"capabilities" => []},
      error: nil
    }
  end

  defp config_delivery(netman_id) do
    config_payload = %{"upstreams" => ["192.0.2.53"], "search_domains" => ["example.test"]}
    {:ok, digest} = Digest.calculate(config_payload)

    %ConfigDelivery{
      envelope: %Envelope{
        protocol_version: 1,
        request_id: @request_id,
        target_type: :netman,
        target_id: netman_id,
        operation: "netman.resolved.config.update",
        idempotency_key: @event_id,
        payload: config_payload,
        payload_digest: digest,
        expected_revision: nil,
        config_version: 1,
        sent_at: @observed_at
      }
    }
  end

  defp config_state(version) do
    %ConfigState{
      target_type: :netman,
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

  defp event(netman_id) do
    %Event{
      target_type: :netman,
      target_id: netman_id,
      event_id: @event_id,
      name: "runtime.link.changed",
      payload: %{"interface" => "eth0"},
      observed_at: @observed_at
    }
  end

  defp publish_config(netman_id, profile_id \\ "office") do
    ManagementCore.publish_netman_config(netman_id, %{
      operation: "netman.profiles.replace",
      payload: %{
        "profiles" => [
          %{
            "profile_id" => profile_id,
            "type" => "ethernet",
            "interface" => "eth0",
            "autoconnect" => true,
            "autoconnect_priority" => 100,
            "zone" => "trusted",
            "ethernet" => %{"mtu" => 1_500},
            "ipv4" => %{
              "method" => "auto",
              "address" => nil,
              "gateway" => nil,
              "dns" => [],
              "dns_search" => []
            },
            "ipv6" => %{
              "method" => "auto",
              "address" => nil,
              "gateway" => nil,
              "dns" => [],
              "dns_search" => []
            }
          }
        ]
      },
      expected_revision: nil
    })
  end

  defp payload(message, publication_sequence \\ nil) do
    %{"message" => encode(message), "publication_sequence" => publication_sequence}
  end

  defp encode(message) do
    assert {:ok, encoded} = Message.encode(message)
    encoded
  end

  defp register_netman(netman_id) do
    assert {:ok, _netman} = ManagementCore.register_netman(%{id: netman_id, profile: :vm})
  end

  defp unique_id(prefix),
    do: "#{prefix}-#{Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)}"
end
