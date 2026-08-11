defmodule YellowDog.NetmanAgent.ClientTest do
  use ExUnit.Case, async: false

  Code.require_file("../../support/client_fake_socket.ex", __DIR__)
  Code.require_file("../../support/client_fake_timer.ex", __DIR__)
  Code.require_file("../../support/client_fake_clock.ex", __DIR__)

  alias YellowDog.NetmanAgent.Client
  alias YellowDog.NetmanAgent.ClientFakeMonotonicClock
  alias YellowDog.NetmanAgent.ClientFakeSocket
  alias YellowDog.NetmanAgent.ClientFakeTimer
  alias YellowDog.NetmanAgent.ClientFakeWallClock
  alias YellowDog.Sync.Digest
  alias YellowDog.Sync.Envelope
  alias YellowDog.Sync.Error
  alias YellowDog.Sync.Identity.Netman
  alias YellowDog.Sync.Message
  alias YellowDog.Sync.Message.Command
  alias YellowDog.Sync.Message.ConfigDelivery
  alias YellowDog.Sync.Message.ConfigState
  alias YellowDog.Sync.Message.Heartbeat
  alias YellowDog.Sync.Message.Hello
  alias YellowDog.Sync.Message.Journal
  alias YellowDog.Sync.Message.Query
  alias YellowDog.Sync.Message.Result
  alias YellowDog.Sync.Message.Status

  @netman_id "netman-east-1"
  @operation "netman.profiles.replace"
  @token "task-7-secret-token"
  @revision String.duplicate("a", 64)
  @sent_at ~U[2026-08-10 00:00:00Z]

  defmodule Dispatcher do
    @moduledoc false

    def configure(owner, replies) do
      {:ok, agent} = Agent.start_link(fn -> replies end)
      :persistent_term.put({__MODULE__, :state}, {owner, agent})
      agent
    end

    def dispatch(envelope, opts) do
      {owner, agent} = :persistent_term.get({__MODULE__, :state})
      send(owner, {:dispatch, envelope, opts})

      Agent.get_and_update(agent, fn
        [reply | rest] -> {reply, rest}
        [] -> {{:error, Error.new(:internal, "internal error", %{})}, []}
      end)
    end
  end

  defmodule QueryDispatcher do
    @moduledoc false

    def configure(owner, replies) do
      {:ok, agent} = Agent.start_link(fn -> replies end)
      :persistent_term.put({__MODULE__, :state}, {owner, agent})
      agent
    end

    def dispatch(envelope, opts) do
      {owner, agent} = :persistent_term.get({__MODULE__, :state})
      send(owner, {:query_dispatch, envelope, opts})

      Agent.get_and_update(agent, fn
        [reply | rest] -> {reply, rest}
        [] -> {{:error, Error.new(:internal, "internal error", %{})}, []}
      end)
    end
  end

  defmodule Owner do
    @moduledoc false

    use GenServer

    def start_link(owner, opts \\ []) do
      GenServer.start_link(__MODULE__, {owner, opts})
    end

    @impl true
    def init({owner, opts}) do
      {:ok,
       %{
         owner: owner,
         journal: %Journal{
           target_type: :netman,
           target_id: Keyword.get(opts, :journal_target_id, "netman-east-1"),
           entries: []
         },
         config_publications: Keyword.get(opts, :config_publications, []),
         config_apply_status: Keyword.get(opts, :config_apply_status, :applied),
         config_outbox: [],
         rollback_pending: false,
         block_config_apply: Keyword.get(opts, :block_config_apply, false),
         pending_config_apply: nil,
         config_snapshot:
           Keyword.get(opts, :config_snapshot, %{
             runtime_status: :unconfigured,
             known_good: nil
           })
       }}
    end

    @impl true
    def handle_call(:wire_projection, _from, state) do
      send(state.owner, :journal_projection)
      {:reply, {:ok, state.journal}, state}
    end

    def handle_call({:apply, envelope}, from, %{block_config_apply: true} = state) do
      send(state.owner, {:config_apply, envelope})
      {:noreply, %{state | pending_config_apply: from}}
    end

    def handle_call({:apply, envelope}, _from, state) do
      send(state.owner, {:config_apply, envelope})
      outbox = state.config_publications

      next_state = %{
        state
        | config_outbox: outbox,
          rollback_pending: state.config_apply_status == :provisional
      }

      {:reply, {:ok, %{status: state.config_apply_status, publications: outbox}}, next_state}
    end

    def handle_call(:confirm, _from, %{rollback_pending: true} = state) do
      send(state.owner, :rollback_confirmed)
      {:reply, {:ok, %{status: :applied, publications: []}}, %{state | rollback_pending: false}}
    end

    def handle_call(:confirm, _from, state), do: {:reply, {:ok, :idle}, state}

    def handle_call(:pending_publications, _from, state) do
      {:reply, {:ok, state.config_outbox}, state}
    end

    def handle_call(:snapshot, _from, state) do
      {:reply, {:ok, state.config_snapshot}, state}
    end

    def handle_call({:acknowledge_publication, sequence}, _from, state) do
      send(state.owner, {:config_ack, sequence})

      case state.config_outbox do
        [%{sequence: ^sequence} | rest] ->
          {:reply, {:ok, %{outbox: rest}}, %{state | config_outbox: rest}}

        _other ->
          {:reply, {:error, Error.new(:conflict, "operation conflict", %{})}, state}
      end
    end

    @impl true
    def handle_info(:release_config_apply, %{pending_config_apply: from} = state)
        when not is_nil(from) do
      GenServer.reply(from, {:ok, %{status: :applied, publications: []}})
      {:noreply, %{state | pending_config_apply: nil}}
    end
  end

  setup do
    ClientFakeSocket.configure(self())
    ClientFakeTimer.configure(self())
    ClientFakeMonotonicClock.configure([0])
    ClientFakeWallClock.configure([@sent_at])
    Dispatcher.configure(self(), [])
    QueryDispatcher.configure(self(), [])

    on_exit(fn ->
      ClientFakeSocket.clear()
      ClientFakeTimer.clear()
      ClientFakeMonotonicClock.clear()
      ClientFakeWallClock.clear()
    end)

    :ok
  end

  test "production socket selects the Netman forwarding channel" do
    assert {:ok, socket} =
             Client.Socket.start_link(
               url: "ws://127.0.0.1:1/netman/ws/websocket",
               params: %{"netman_id" => @netman_id}
             )

    on_exit(fn -> Client.Socket.stop(socket) end)

    assert Phoenix.SocketClient.get_state(socket, :default_channel_module) ==
             Client.SocketChannel
  end

  test "Netman socket channel forwards the sync event and channel identity" do
    channel = self()
    payload = %{"message" => "encoded-netman-command"}

    state = %Phoenix.SocketClient.Channel.State{
      caller: channel,
      topic: "netman:control:netman-east-1"
    }

    assert {:noreply, ^state} = Client.SocketChannel.handle_message("sync", payload, state)
    assert_receive {:yellow_dog_socket_message, ^channel, "sync", ^payload}
  end

  test "disabled client is inert" do
    name = unique_name()
    assert {:ok, client} = Client.start_link(enabled: false, name: name)
    refute Client.connected?(client)
    assert Client.connection_state(client) == :disabled
    refute_receive {:socket_start, _opts}
  end

  test "validates all connection inputs before starting a socket" do
    {:ok, owner} = Owner.start_link(self())

    invalid = [
      [],
      [enabled: true],
      Keyword.delete(base_opts(owner), :token),
      Keyword.put(base_opts(owner), :token, ""),
      Keyword.put(base_opts(owner), :management_url, "http://management.example.test:4443"),
      Keyword.put(
        base_opts(owner),
        :management_url,
        "https://user:pass@management.example.test:4443"
      ),
      Keyword.put(
        base_opts(owner),
        :management_url,
        "https://management.example.test:4443?token=leak"
      ),
      Keyword.put(base_opts(owner), :identity, %{id: @netman_id}),
      Keyword.put(base_opts(owner), :identity, identity(id: "")),
      Keyword.put(base_opts(owner), :identity, identity(id: "../netman")),
      Keyword.put(base_opts(owner), :identity, identity(id: "netman/child")),
      Keyword.put(base_opts(owner), :identity, identity(id: "netman\u0000control")),
      Keyword.put(base_opts(owner), :command_journal, make_ref()),
      Keyword.put(base_opts(owner), :config_store, make_ref()),
      Keyword.put(base_opts(owner), :config_applier, make_ref()),
      Keyword.put(base_opts(owner), :config_apply_store, make_ref()),
      Keyword.put(base_opts(owner), :rollback_timer, make_ref()),
      Keyword.put(base_opts(owner), :heartbeat_interval, 0),
      Keyword.put(base_opts(owner), :heartbeat_interval, 4_294_967_296),
      Keyword.put(base_opts(owner), :connection_poll_interval, 501),
      Keyword.put(base_opts(owner), :initial_backoff, 251),
      Keyword.put(base_opts(owner), :unknown, true),
      base_opts(owner) ++ [token: @token]
    ]

    for opts <- invalid do
      assert {:error, :invalid_options} = Client.start_link(opts)
    end

    assert {:error, :invalid_options} = Client.start_link(:invalid)
    refute_receive {:socket_start, _opts}
  end

  test "joins the concrete Netman topic and sends Hello, Status, then Journal" do
    {:ok, owner} = Owner.start_link(self())
    {:ok, client} = Client.start_link(base_opts(owner))

    assert_receive {:socket_start,
                    [
                      url: "wss://management.example.test:4443/netman/ws/websocket",
                      params: %{"netman_id" => @netman_id, "token" => @token}
                    ]}

    assert_receive {:socket_join, _socket, "netman:control:" <> @netman_id, %{}, 200}
    assert_receive {:socket_channel, channel}

    assert %Hello{identity: %Netman{id: @netman_id}} = receive_push(channel)

    assert %Status{
             target_type: :netman,
             target_id: @netman_id,
             state: :online,
             details: %{
               "capabilities" => ["profiles.validate", "runtime.capabilities"],
               "config_revision" => @revision,
               "config_runtime_status" => "unconfigured",
               "profile" => "managed",
               "version" => "1.0.0"
             }
           } = receive_push(channel)

    assert_receive :journal_projection

    assert %Journal{target_type: :netman, target_id: @netman_id, entries: []} =
             receive_push(channel)

    assert Client.connected?(client)
    assert Client.connection_state(client) == :active
  end

  test "publishes unknown config runtime state as degraded" do
    {:ok, owner} =
      Owner.start_link(self(),
        config_snapshot: %{runtime_status: :unknown, known_good: nil}
      )

    {:ok, _client} = Client.start_link(base_opts(owner))
    assert_receive {:socket_start, _opts}
    assert_receive {:socket_join, _socket, _topic, %{}, 200}
    assert_receive {:socket_channel, channel}
    assert %Hello{} = receive_push(channel)

    assert %Status{
             state: :degraded,
             details: %{
               "config_runtime_status" => "unknown",
               "config_revision" => @revision
             }
           } = receive_push(channel)
  end

  test "does not retain the token in inspectable Client state" do
    {:ok, owner} = Owner.start_link(self())
    {:ok, client} = Client.start_link(base_opts(owner))
    _channel = finish_handshake()

    refute inspect(:sys.get_state(client), limit: :infinity) =~ @token
  end

  test "rejects a durable Journal for a different concrete Netman" do
    {:ok, owner} = Owner.start_link(self(), journal_target_id: "netman-west-1")
    {:ok, client} = Client.start_link(base_opts(owner))

    assert_receive {:socket_channel, channel}
    assert %Hello{} = receive_push(channel)
    assert %Status{} = receive_push(channel)
    assert_receive :journal_projection

    refute_receive {:socket_push, ^channel, "sync", _payload, 200}, 20
    assert_receive {:timer_scheduled, ^client, {:rejoin, 1}, 100, _ref}
    assert Client.connection_state(client) == :backoff
  end

  test "publishes generation-bound typed heartbeat and status messages" do
    {:ok, owner} = Owner.start_link(self())
    {:ok, client} = Client.start_link(base_opts(owner))
    channel = finish_handshake()

    assert_receive {:timer_scheduled, ^client, {:heartbeat, generation}, 1_000, _ref}
    assert_receive {:timer_scheduled, ^client, {:status, ^generation}, 2_000, _ref}

    send(client, {:heartbeat, generation + 1})
    refute_receive {:socket_push, ^channel, "sync", _payload, 200}, 20

    send(client, {:heartbeat, generation})

    assert %Heartbeat{target_type: :netman, target_id: @netman_id} = receive_push(channel)
    assert_receive {:timer_scheduled, ^client, {:heartbeat, ^generation}, 1_000, _ref}

    send(client, {:status, generation})
    assert %Status{target_type: :netman, target_id: @netman_id} = receive_push(channel)
  end

  test "routes Command and Query to separate dispatchers and correlates Results" do
    {:ok, owner} = Owner.start_link(self())

    command_result = %{"profile_id" => "office", "valid" => true, "errors" => []}
    query_result = %{"capabilities" => ["runtime.capabilities"]}
    Dispatcher.configure(self(), [{:ok, command_result}])
    QueryDispatcher.configure(self(), [{:ok, query_result}])

    {:ok, client} = Client.start_link(base_opts(owner))
    channel = finish_handshake()

    command = command_message()
    command_envelope = command.envelope
    command_request_id = command.envelope.request_id
    ClientFakeSocket.channel_message(client, channel, wire(command))

    assert_receive {:dispatch, ^command_envelope,
                    [
                      netman_id: @netman_id,
                      capabilities: ["profiles.validate", "runtime.capabilities"],
                      command_journal: ^owner,
                      runtime_adapter: Dispatcher
                    ]}

    assert %Result{
             request_id: ^command_request_id,
             target_type: :netman,
             operation: "netman.profiles.validate",
             value: ^command_result,
             error: nil
           } = receive_push(channel)

    query = query_message()
    query_envelope = query.envelope
    query_request_id = query.envelope.request_id
    ClientFakeSocket.channel_message(client, channel, wire(query))

    assert_receive {:query_dispatch, ^query_envelope,
                    [
                      netman_id: @netman_id,
                      capabilities: ["profiles.validate", "runtime.capabilities"],
                      runtime_adapter: QueryDispatcher
                    ]}

    assert %Result{
             request_id: ^query_request_id,
             target_type: :netman,
             operation: "netman.runtime.capabilities.get",
             value: ^query_result,
             error: nil
           } = receive_push(channel)
  end

  test "rejects malformed, unsupported, and cross-ID messages" do
    {:ok, owner} = Owner.start_link(self())
    {:ok, client} = Client.start_link(base_opts(owner))
    channel = finish_handshake()

    command = command_message()
    {:ok, canonical} = Message.encode(command)

    invalid_payloads = [
      %{"message" => canonical},
      %{"message" => " " <> canonical, "publication_sequence" => nil},
      wire(%Hello{identity: identity()}),
      wire(command_message(target_id: "netman-west-1"))
    ]

    Enum.each(invalid_payloads, fn payload ->
      ClientFakeSocket.channel_message(client, channel, payload)
    end)

    ClientFakeSocket.channel_message(client, channel, "legacy", wire(command))

    refute_receive {:dispatch, _envelope, _opts}, 50
    refute_receive {:query_dispatch, _envelope, _opts}, 50
    refute_receive {:socket_push, ^channel, "sync", _payload, 200}, 50
    assert Client.connection_state(client) == :active
  end

  test "applies ConfigDelivery and publishes every durable ConfigState in order" do
    publications = config_publications()
    {:ok, owner} = Owner.start_link(self(), config_publications: publications)

    ClientFakeSocket.clear()

    ClientFakeSocket.configure(self(),
      pushes:
        List.duplicate({:ok, %{"accepted" => true}}, 3) ++
          Enum.map(publications, &{:ok, receipt(&1)})
    )

    {:ok, client} = Client.start_link(base_opts(owner))
    channel = finish_handshake()
    delivery = config_delivery()
    envelope = delivery.envelope

    ClientFakeSocket.channel_message(client, channel, wire(delivery))

    assert_receive {:config_apply, ^envelope}

    for publication <- publications do
      assert_publication(channel, publication)
      assert_receive {:config_ack, sequence}
      assert sequence == publication.sequence
    end

    assert Client.connection_state(client) == :active
  end

  test "continues heartbeats while a config application is in progress" do
    {:ok, owner} = Owner.start_link(self(), block_config_apply: true)
    {:ok, client} = Client.start_link(base_opts(owner))
    channel = finish_handshake()
    delivery = config_delivery()

    ClientFakeSocket.channel_message(client, channel, wire(delivery))
    assert_receive {:config_apply, envelope}
    assert envelope == delivery.envelope

    assert Client.connection_state(client) == :active
    send(client, {:heartbeat, 1})
    assert %Heartbeat{target_id: @netman_id} = receive_push(channel)

    send(owner, :release_config_apply)
  end

  test "serializes a newer delivery behind the in-progress config application" do
    {:ok, owner} = Owner.start_link(self(), block_config_apply: true)
    {:ok, client} = Client.start_link(base_opts(owner))
    channel = finish_handshake()
    first = config_delivery()

    second = %ConfigDelivery{
      envelope: %{
        first.envelope
        | request_id: "44444444-4444-4444-8444-444444444444",
          idempotency_key: "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
          config_version: 2
      }
    }

    ClientFakeSocket.channel_message(client, channel, wire(first))
    assert_receive {:config_apply, first_envelope}
    assert first_envelope.config_version == 1

    ClientFakeSocket.channel_message(client, channel, wire(second))
    refute_receive {:config_apply, %{config_version: 2}}, 50

    send(owner, :release_config_apply)
    assert_receive {:config_apply, second_envelope}
    assert second_envelope.config_version == 2
    send(owner, :release_config_apply)
  end

  test "forces a reconnect for provisional config and confirms it after a successful handshake" do
    publications = Enum.take(config_publications(), 2)

    {:ok, owner} =
      Owner.start_link(self(),
        config_publications: publications,
        config_apply_status: :provisional
      )

    ClientFakeSocket.clear()

    ClientFakeSocket.configure(self(),
      pushes:
        List.duplicate({:ok, %{"accepted" => true}}, 3) ++
          Enum.map(publications, &{:ok, receipt(&1)}) ++
          List.duplicate({:ok, %{"accepted" => true}}, 3)
    )

    {:ok, client} = Client.start_link(base_opts(owner))
    channel = finish_handshake()
    ClientFakeSocket.channel_message(client, channel, wire(config_delivery()))

    assert_receive {:config_apply, _envelope}

    for publication <- publications do
      assert_publication(channel, publication)
      assert_receive {:config_ack, sequence}
      assert sequence == publication.sequence
    end

    assert_receive {:timer_scheduled, ^client, {:rejoin, 1}, 100, _ref}
    refute_receive :rollback_confirmed

    send(client, {:rejoin, 1})
    assert_receive {:socket_start, _opts}
    _new_channel = finish_handshake()
    assert_receive :rollback_confirmed
    assert Client.connection_state(client) == :active
  end

  test "reconnect replays an unacknowledged ConfigState without applying again" do
    [publication | _rest] = config_publications()
    {:ok, owner} = Owner.start_link(self(), config_publications: [publication])

    ClientFakeSocket.clear()

    ClientFakeSocket.configure(self(),
      pushes:
        List.duplicate({:ok, %{"accepted" => true}}, 3) ++
          [{:error, :closed}] ++
          List.duplicate({:ok, %{"accepted" => true}}, 3) ++
          [{:ok, receipt(publication)}]
    )

    {:ok, client} = Client.start_link(base_opts(owner))
    channel = finish_handshake()
    delivery = config_delivery()
    envelope = delivery.envelope

    ClientFakeSocket.channel_message(client, channel, wire(delivery))

    assert_receive {:config_apply, ^envelope}
    assert_receive {:socket_push, ^channel, "sync", %{"publication_sequence" => 1}, 200}

    refute_receive {:config_ack, 1}
    assert_receive {:timer_scheduled, ^client, {:rejoin, 1}, 100, _ref}

    send(client, {:rejoin, 1})
    assert_receive {:socket_start, _opts}
    replay_channel = finish_handshake()
    assert_publication(replay_channel, publication)
    assert_receive {:config_ack, 1}
    refute_receive {:config_apply, _envelope}
  end

  test "malformed ConfigState receipt is never acknowledged locally" do
    [publication | _rest] = config_publications()
    {:ok, owner} = Owner.start_link(self(), config_publications: [publication])

    ClientFakeSocket.clear()

    ClientFakeSocket.configure(self(),
      pushes:
        List.duplicate({:ok, %{"accepted" => true}}, 3) ++
          [{:ok, %{"accepted" => true}}]
    )

    {:ok, client} = Client.start_link(base_opts(owner))
    channel = finish_handshake()
    ClientFakeSocket.channel_message(client, channel, wire(config_delivery()))

    assert_receive {:config_apply, _envelope}
    assert_publication(channel, publication)
    refute_receive {:config_ack, 1}
    assert_receive {:timer_scheduled, ^client, {:flush_config, _generation}, 100, _ref}
    assert Client.connection_state(client) == :active
  end

  test "uses bounded exponential backoff and ignores stale rejoin timers" do
    ClientFakeSocket.clear()

    ClientFakeSocket.configure(self(),
      starts: [{:error, :closed}, {:error, :closed}, {:error, :closed}, {:error, :closed}]
    )

    {:ok, owner} = Owner.start_link(self())
    {:ok, client} = Client.start_link(base_opts(owner))

    assert_receive {:socket_start, _opts}
    assert_receive {:timer_scheduled, ^client, {:rejoin, 1}, 100, _ref}

    send(client, {:rejoin, 99})
    refute_receive {:socket_start, _opts}, 20

    send(client, {:rejoin, 1})
    assert_receive {:socket_start, _opts}
    assert_receive {:timer_scheduled, ^client, {:rejoin, 2}, 200, _ref}

    send(client, {:rejoin, 2})
    assert_receive {:socket_start, _opts}
    assert_receive {:timer_scheduled, ^client, {:rejoin, 3}, 250, _ref}

    send(client, {:rejoin, 3})
    assert_receive {:socket_start, _opts}
    assert_receive {:timer_scheduled, ^client, {:rejoin, 4}, 250, _ref}
  end

  test "reconnects after channel loss and ignores messages from the old channel" do
    {:ok, owner} = Owner.start_link(self())
    result = %{"profile_id" => "office", "valid" => true, "errors" => []}
    Dispatcher.configure(self(), [{:ok, result}])

    {:ok, client} = Client.start_link(base_opts(owner))
    old_channel = finish_handshake()
    Process.exit(old_channel, :kill)

    assert_receive {:timer_scheduled, ^client, {:rejoin, 1}, 100, _ref}

    command = command_message()
    ClientFakeSocket.channel_message(client, old_channel, wire(command))
    refute_receive {:dispatch, _envelope, _opts}, 20

    send(client, {:rejoin, 1})
    assert_receive {:socket_start, _opts}
    new_channel = finish_handshake()
    refute new_channel == old_channel

    ClientFakeSocket.channel_message(client, old_channel, wire(command))
    refute_receive {:dispatch, _envelope, _opts}, 20

    ClientFakeSocket.channel_message(client, new_channel, wire(command))
    assert_receive {:dispatch, _envelope, _opts}
    assert %Result{value: ^result} = receive_push(new_channel)
  end

  defp base_opts(owner) do
    [
      enabled: true,
      management_url: "https://management.example.test:4443/base",
      token: @token,
      identity: identity(),
      dispatcher: Dispatcher,
      dispatcher_runtime_adapter: Dispatcher,
      query_dispatcher: QueryDispatcher,
      query_runtime_adapter: QueryDispatcher,
      command_journal: owner,
      config_store: owner,
      config_applier: owner,
      config_apply_store: owner,
      rollback_timer: owner,
      socket: ClientFakeSocket,
      timer: ClientFakeTimer,
      monotonic_clock: ClientFakeMonotonicClock,
      wall_clock: ClientFakeWallClock,
      connection_poll_interval: 50,
      connect_timeout: 500,
      join_timeout: 200,
      push_timeout: 200,
      heartbeat_interval: 1_000,
      status_interval: 2_000,
      initial_backoff: 100,
      max_backoff: 250,
      name: unique_name()
    ]
  end

  defp identity(opts \\ []) do
    %Netman{
      id: Keyword.get(opts, :id, @netman_id),
      name: "Netman East",
      version: "1.0.0",
      profile: "managed",
      capabilities: ["profiles.validate", "runtime.capabilities"],
      config_revision: @revision
    }
  end

  defp finish_handshake do
    assert_receive {:socket_channel, channel}
    assert %Hello{} = receive_push(channel)
    assert %Status{} = receive_push(channel)
    assert_receive :journal_projection
    assert %Journal{} = receive_push(channel)
    channel
  end

  defp receive_push(channel) do
    assert_receive {:socket_push, ^channel, "sync",
                    %{"message" => encoded, "publication_sequence" => nil}, 200}

    assert {:ok, message} = Message.decode(encoded)
    message
  end

  defp wire(message) do
    {:ok, encoded} = Message.encode(message)
    %{"message" => encoded, "publication_sequence" => nil}
  end

  defp command_message(opts \\ []) do
    %Command{envelope: envelope(:command, opts)}
  end

  defp query_message(opts \\ []) do
    %Query{envelope: envelope(:query, opts)}
  end

  defp config_delivery do
    %ConfigDelivery{envelope: envelope(:config, [])}
  end

  defp config_publications do
    delivery = config_delivery().envelope

    [:delivered, :applying, :applied]
    |> Enum.with_index(1)
    |> Enum.map(fn {state, sequence} ->
      message = %ConfigState{
        target_type: :netman,
        target_id: @netman_id,
        operation: @operation,
        state: state,
        version: 1,
        digest: delivery.payload_digest,
        applied_revision: if(state == :applied, do: @revision),
        previous_version: nil,
        previous_revision: nil,
        failure: nil,
        rollback: nil,
        observed_at: @sent_at
      }

      {:ok, encoded_message} = Message.encode(message)
      %{sequence: sequence, encoded_message: encoded_message, message: message}
    end)
  end

  defp receipt(publication) do
    %{
      "target_type" => "netman",
      "target_id" => @netman_id,
      "publication_sequence" => publication.sequence,
      "state_revision" => publication.sequence
    }
  end

  defp assert_publication(channel, publication) do
    assert_receive {:socket_push, ^channel, "sync",
                    %{
                      "message" => encoded,
                      "publication_sequence" => sequence
                    }, 200}

    assert sequence == publication.sequence
    assert encoded == publication.encoded_message
  end

  defp envelope(kind, opts) do
    {operation, payload, request_id, idempotency_key, config_version} =
      case kind do
        :command ->
          {"netman.profiles.validate", profile_payload(), "11111111-1111-4111-8111-111111111111",
           "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", nil}

        :query ->
          {"netman.runtime.capabilities.get", %{}, "22222222-2222-4222-8222-222222222222",
           "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", nil}

        :config ->
          {"netman.profiles.replace", %{"profiles" => []}, "33333333-3333-4333-8333-333333333333",
           "cccccccc-cccc-4ccc-8ccc-cccccccccccc", 1}
      end

    payload = Keyword.get(opts, :payload, payload)
    {:ok, payload_digest} = Digest.calculate(payload)

    %Envelope{
      protocol_version: 1,
      request_id: request_id,
      target_type: :netman,
      target_id: Keyword.get(opts, :target_id, @netman_id),
      operation: operation,
      idempotency_key: idempotency_key,
      payload: payload,
      payload_digest: payload_digest,
      expected_revision: nil,
      config_version: config_version,
      sent_at: @sent_at
    }
  end

  defp unique_name do
    {:global, {__MODULE__, System.unique_integer([:positive])}}
  end

  defp profile_payload do
    %{
      "profile_id" => "office",
      "type" => "ethernet",
      "interface" => nil,
      "autoconnect" => true,
      "autoconnect_priority" => 0,
      "zone" => "default",
      "ethernet" => %{"mtu" => nil},
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
  end
end
