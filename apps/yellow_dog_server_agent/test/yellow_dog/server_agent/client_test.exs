defmodule YellowDog.ServerAgent.ClientTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  Code.require_file("../../support/client_fake_socket.ex", __DIR__)
  Code.require_file("../../support/client_fake_timer.ex", __DIR__)
  Code.require_file("../../support/client_fake_clock.ex", __DIR__)

  alias YellowDog.ServerAgent.Client
  alias YellowDog.ServerAgent.ClientFakeMonotonicClock
  alias YellowDog.ServerAgent.ClientFakeSocket
  alias YellowDog.ServerAgent.ClientFakeTimer
  alias YellowDog.ServerAgent.ClientFakeWallClock
  alias YellowDog.Sync.Digest
  alias YellowDog.Sync.Envelope
  alias YellowDog.Sync.Error
  alias YellowDog.Sync.Identity.Server
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

  @server_id "server-east-1"
  @token "task-9b-secret-token"
  @revision String.duplicate("a", 64)
  @sent_at ~U[2026-07-17 10:00:00Z]
  @later ~U[2026-07-17 10:00:01Z]
  @required_enabled_keys [
    :enabled,
    :management_url,
    :token,
    :identity,
    :dispatcher,
    :dispatcher_runtime_adapter,
    :command_journal,
    :config_applier,
    :config_apply_store,
    :socket,
    :timer,
    :monotonic_clock,
    :wall_clock,
    :connection_poll_interval,
    :connect_timeout,
    :join_timeout,
    :push_timeout,
    :heartbeat_interval,
    :status_interval,
    :initial_backoff,
    :max_backoff
  ]

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
         journal:
           Keyword.get(opts, :journal, %Journal{
             target_type: :server,
             target_id: "server-east-1",
             entries: []
           }),
         publications: Keyword.get(opts, :publications, []),
         apply_replies: Keyword.get(opts, :apply_replies, []),
         acknowledge_replies: Keyword.get(opts, :acknowledge_replies, [])
       }}
    end

    @impl true
    def handle_call(:wire_projection, _from, state) do
      send(state.owner, :journal_projection)
      {:reply, {:ok, state.journal}, state}
    end

    def handle_call(:pending_publications, _from, state) do
      send(state.owner, :pending_publications)
      {:reply, {:ok, state.publications}, state}
    end

    def handle_call({:acknowledge_publication, sequence}, _from, state) do
      send(state.owner, {:acknowledge_publication, sequence})

      case state.acknowledge_replies do
        [reply | rest] ->
          {:reply, reply, %{state | acknowledge_replies: rest}}

        [] ->
          publications = Enum.reject(state.publications, &(&1.sequence == sequence))
          {:reply, {:ok, %{outbox: publications}}, %{state | publications: publications}}
      end
    end

    def handle_call(:publications, _from, state),
      do: {:reply, state.publications, state}

    def handle_call({:apply, envelope}, _from, state) do
      send(state.owner, {:config_apply, envelope})

      case state.apply_replies do
        [reply | rest] ->
          state =
            case reply do
              {:ok, %{publications: publications}} ->
                %{state | apply_replies: rest, publications: publications}

              _other ->
                %{state | apply_replies: rest}
            end

          {:reply, reply, state}

        [] ->
          {:reply, {:ok, %{status: :replay, publications: state.publications}}, state}
      end
    end
  end

  setup do
    ClientFakeSocket.configure(self())
    ClientFakeTimer.configure(self())
    ClientFakeMonotonicClock.configure([0])
    ClientFakeWallClock.configure([@sent_at, @later])
    Dispatcher.configure(self(), [])

    on_exit(fn ->
      ClientFakeSocket.clear()
      ClientFakeTimer.clear()
      ClientFakeMonotonicClock.clear()
      ClientFakeWallClock.clear()
    end)

    :ok
  end

  test "disabled client is inert and needs no network configuration" do
    name = unique_name()
    assert {:ok, client} = Client.start_link(enabled: false, name: name)
    assert Client.child_spec(enabled: false, name: name).id == name
    refute Client.connected?(client)
    assert Client.connection_state(client) == :disabled
    refute_receive {:socket_start, _opts}
  end

  test "rejects duplicate, unknown, and malformed enabled options" do
    {:ok, owner} = Owner.start_link(self())

    invalid = [
      [],
      [enabled: true],
      Keyword.put(base_opts(owner), :management_url, "http://management.example.test"),
      Keyword.put(base_opts(owner), :management_url, "wss://management.example.test"),
      Keyword.put(base_opts(owner), :token, ""),
      Keyword.put(base_opts(owner), :identity, %{id: @server_id}),
      Keyword.put(base_opts(owner), :heartbeat_interval, 0),
      Keyword.put(base_opts(owner), :initial_backoff, 2_000),
      Keyword.put(base_opts(owner), :unknown, true),
      base_opts(owner) ++ [token: "duplicate"]
    ]

    for opts <- invalid do
      assert {:error, :invalid_options} = Client.start_link(opts)
    end

    assert {:error, :invalid_options} = Client.start_link(:invalid)
    assert {:error, :invalid_options} = Client.start_link(enabled: false, token: @token)
  end

  test "enabled mode rejects deletion of every required explicit option" do
    {:ok, owner} = Owner.start_link(self())

    for key <- @required_enabled_keys do
      result =
        owner
        |> base_opts()
        |> Keyword.delete(key)
        |> Client.start_link()

      assert result == {:error, :invalid_options},
             "missing enabled option #{inspect(key)} was accepted"
    end
  end

  test "accepts only strict HTTPS management authorities and valid ports" do
    {:ok, owner} = Owner.start_link(self())

    invalid_urls = [
      "http://management.example.test",
      "wss://management.example.test",
      "https://",
      "https://:443",
      "https://management.example.test:",
      "https://management.example.test:/base",
      "https://management.example.test:alpha",
      "https://management.example.test:0",
      "https://management.example.test:65536",
      "https://management example.test",
      "https://user@management.example.test",
      "https://management.example.test?query=true",
      "https://management.example.test#fragment",
      "https://-management.example.test",
      "https://management_.example.test",
      "https://management..example.test"
    ]

    for url <- invalid_urls do
      result =
        owner
        |> base_opts()
        |> Keyword.put(:management_url, url)
        |> Client.start_link()

      assert result == {:error, :invalid_options},
             "invalid management URL #{inspect(url)} was accepted"
    end
  end

  test "derives canonical endpoints for default, explicit default, and IPv6 ports" do
    {:ok, owner} = Owner.start_link(self())

    cases = [
      {"https://management.example.test/base",
       "wss://management.example.test/server/ws/websocket"},
      {"https://MANAGEMENT.example.test:443/base",
       "wss://management.example.test/server/ws/websocket"},
      {"https://[2001:db8::1]:4443/base", "wss://[2001:db8::1]:4443/server/ws/websocket"}
    ]

    for {management_url, expected_url} <- cases do
      assert {:ok, client} =
               owner
               |> base_opts()
               |> Keyword.put(:management_url, management_url)
               |> Client.start_link()

      assert_receive {:socket_start, socket_opts}
      assert socket_opts[:url] == expected_url
      assert socket_opts[:params] == %{"token" => @token, "server_id" => @server_id}
      GenServer.stop(client, :normal)
    end
  end

  test "derives exact TLS endpoint, params, topic, and activates after Hello then Status" do
    {:ok, owner} = Owner.start_link(self())
    {:ok, client} = start_client(owner)

    assert_receive {:socket_start, socket_opts}

    assert socket_opts == [
             url: "wss://management.example.test:4443/server/ws/websocket",
             params: %{"token" => @token, "server_id" => @server_id}
           ]

    assert_receive {:socket_join, _socket, "server:control:" <> @server_id, %{}, 400}
    assert_receive {:socket_channel, channel}

    assert_receive {:socket_push, ^channel, "sync", hello_payload, 500}
    assert %{"message" => hello_encoded, "publication_sequence" => nil} = hello_payload
    assert map_size(hello_payload) == 2
    assert {:ok, %Hello{identity: %Server{id: @server_id}}} = Message.decode(hello_encoded)

    assert_receive {:socket_push, ^channel, "sync", status_payload, 500}
    assert %{"message" => status_encoded, "publication_sequence" => nil} = status_payload

    assert {:ok, %Status{target_type: :server, target_id: @server_id, state: :online}} =
             Message.decode(status_encoded)

    assert Client.connected?(client)
    assert Client.connection_state(client) == :active
    assert_receive :journal_projection
    assert_receive {:socket_push, ^channel, "sync", journal_payload, 500}
    assert {:ok, %Journal{entries: []}} = decode_payload(journal_payload)
  end

  test "does not activate or reset backoff until both handshake replies are exact" do
    ClientFakeSocket.set_pushes([
      {:ok, %{"accepted" => true}},
      {:ok, %{"accepted" => true, "extra" => true}},
      {:ok, %{"accepted" => true}},
      {:error, :closed}
    ])

    {:ok, owner} = Owner.start_link(self())
    {:ok, client} = start_client(owner)
    refute Client.connected?(client)
    assert Client.connection_state(client) == :backoff
    assert_receive {:timer_scheduled, ^client, {:rejoin, 1}, 100, _ref}

    send(client, {:rejoin, 1})
    assert_receive {:socket_start, _opts}
    assert_receive {:timer_scheduled, ^client, {:rejoin, 2}, 200, _ref}
  end

  test "uploads terminal journal evidence without claiming pending records terminal" do
    terminal = %{
      "request_id" => "11111111-1111-4111-8111-111111111111",
      "operation" => "server.runtime.services.start",
      "status" => "completed",
      "result" => %{"service" => "dns", "state" => "running"},
      "error" => nil
    }

    {:ok, owner} =
      Owner.start_link(self(),
        journal: %Journal{target_type: :server, target_id: @server_id, entries: [terminal]}
      )

    {:ok, _client} = start_client(owner)
    channel = receive_channel()
    {_payload, %Journal{entries: entries}} = receive_message(channel, Journal)
    assert entries == [terminal]
    refute Enum.any?(entries, &(&1["status"] == "unknown"))
  end

  test "flushes ConfigState publications in order and acknowledges only exact receipts" do
    first = config_publication(1, :delivered)
    second = config_publication(2, :applying)
    third = config_publication(3, :applied)
    receipts = [receipt(first, 1), receipt(second, 2), receipt(third, 3)]

    ClientFakeSocket.set_pushes(
      List.duplicate({:ok, %{"accepted" => true}}, 3) ++
        Enum.map(receipts, &{:ok, &1})
    )

    {:ok, owner} = Owner.start_link(self(), publications: [first, second, third])
    {:ok, _client} = start_client(owner)
    channel = receive_channel()
    drain_activation(channel)

    for publication <- [first, second, third] do
      assert_receive {:socket_push, ^channel, "sync", payload, 500}

      assert payload == %{
               "message" => publication.encoded_message,
               "publication_sequence" => publication.sequence
             }

      assert_receive {:acknowledge_publication, sequence}
      assert sequence == publication.sequence
    end
  end

  test "malformed ConfigState receipt leaves the outbox head and retries without applying again" do
    publication = config_publication(1, :delivered)

    ClientFakeSocket.set_pushes(
      List.duplicate({:ok, %{"accepted" => true}}, 3) ++
        [
          {:ok, Map.put(receipt(publication, 1), "state_revision", 2)},
          {:ok, receipt(publication, 1)}
        ]
    )

    {:ok, owner} =
      Owner.start_link(self(),
        publications: [publication],
        apply_replies: [{:ok, %{status: :applied, publications: [publication]}}]
      )

    {:ok, client} = start_client(owner)
    channel = receive_channel()
    drain_activation(channel)
    refute_receive {:acknowledge_publication, 1}
    assert_receive {:timer_scheduled, ^client, {:flush_config, generation}, 100, _ref}
    assert Client.connection_state(client) == :active
    refute_receive {:socket_stop, _pid}

    send(client, {:flush_config, generation})
    assert_receive {:acknowledge_publication, 1}
    refute_receive {:config_apply, _envelope}
  end

  test "ConfigState transport failure retains the head and enters reconnect backoff" do
    publication = config_publication(1, :delivered)

    ClientFakeSocket.set_pushes(
      List.duplicate({:ok, %{"accepted" => true}}, 3) ++ [{:error, :timeout}]
    )

    {:ok, owner} = Owner.start_link(self(), publications: [publication])
    {:ok, client} = start_client(owner)
    channel = receive_channel()
    drain_activation(channel)

    assert_receive {:socket_stop, _socket}
    assert_receive {:timer_scheduled, ^client, {:rejoin, 1}, 100, _ref}
    assert Client.connection_state(client) == :backoff
    refute_receive {:acknowledge_publication, 1}
    assert GenServer.call(owner, :publications) == [publication]
  end

  test "ConfigState local acknowledgement failure retains the head and retries locally" do
    publication = config_publication(1, :delivered)

    ClientFakeSocket.set_pushes(
      List.duplicate({:ok, %{"accepted" => true}}, 3) ++
        [{:ok, receipt(publication, 1)}, {:ok, receipt(publication, 1)}]
    )

    {:ok, owner} =
      Owner.start_link(self(),
        publications: [publication],
        acknowledge_replies: [{:error, Error.new(:internal, "internal error", %{})}]
      )

    {:ok, client} = start_client(owner)
    channel = receive_channel()
    drain_activation(channel)

    assert_receive {:acknowledge_publication, 1}
    assert_receive {:timer_scheduled, ^client, {:flush_config, generation}, 100, _ref}
    assert Client.connection_state(client) == :active
    refute_receive {:socket_stop, _pid}
    assert GenServer.call(owner, :publications) == [publication]

    send(client, {:flush_config, generation})
    assert_receive {:acknowledge_publication, 1}
    assert GenServer.call(owner, :publications) == []
  end

  test "validates exact failure-phase receipt revisions before acknowledgement" do
    publications = [
      failed_publication(1, "delivery"),
      failed_publication(2, "validation"),
      failed_publication(3, "apply"),
      failed_publication(4, "rollback")
    ]

    revisions = [1, 2, 3, 3]

    replies =
      Enum.zip_with(publications, revisions, fn publication, revision ->
        {:ok, receipt(publication, revision)}
      end)

    ClientFakeSocket.set_pushes(List.duplicate({:ok, %{"accepted" => true}}, 3) ++ replies)

    {:ok, owner} = Owner.start_link(self(), publications: publications)
    {:ok, _client} = start_client(owner)
    channel = receive_channel()
    drain_activation(channel)

    for sequence <- 1..4 do
      assert_receive {:acknowledge_publication, ^sequence}
    end
  end

  test "routes canonical command once and publishes a canonical Result" do
    result = %{"service" => "dns", "state" => "running"}
    Dispatcher.configure(self(), [{:ok, result}])
    {:ok, owner} = Owner.start_link(self())
    {:ok, client} = start_client(owner)
    channel = receive_channel()
    command = command()

    ClientFakeSocket.channel_message(client, channel, sync_payload(command))

    assert_receive {:dispatch, %Envelope{request_id: request_id}, dispatcher_opts}
    assert request_id == command.envelope.request_id
    assert dispatcher_opts[:server_id] == @server_id
    assert dispatcher_opts[:capabilities] == identity().capabilities

    {_payload, %Result{} = published} = receive_message(channel, Result)
    assert published.request_id == command.envelope.request_id
    assert published.operation == command.envelope.operation
    assert published.value == result
    assert published.error == nil
    refute_receive {:dispatch, _, _}
  end

  test "routes production socket messages through the opaque credential provider" do
    result = %{"service" => "dns", "state" => "running"}
    Dispatcher.configure(self(), [{:ok, result}])
    {:ok, owner} = Owner.start_link(self())
    {:ok, _client} = start_client(owner)
    channel = receive_channel()

    ClientFakeSocket.provider_message(channel, sync_payload(command()))

    assert_receive {:dispatch, %Envelope{}, _dispatcher_opts}
    {_payload, %Result{value: ^result}} = receive_message(channel, Result)
  end

  test "routes duplicate commands through Dispatcher replay without client-side duplication" do
    result = %{"service" => "dns", "state" => "running"}
    Dispatcher.configure(self(), [{:ok, result}, {:ok, result}])
    {:ok, owner} = Owner.start_link(self())
    {:ok, client} = start_client(owner)
    channel = receive_channel()
    payload = sync_payload(command())

    ClientFakeSocket.channel_message(client, channel, payload)
    assert_receive {:dispatch, _, _}
    receive_message(channel, Result)

    ClientFakeSocket.channel_message(client, channel, payload)
    assert_receive {:dispatch, _, _}
    receive_message(channel, Result)
    refute_receive {:dispatch, _, _}
  end

  test "routes a canonical Query through Dispatcher exactly once" do
    result = %{
      "items" => [],
      "revision" => @revision,
      "observed_at" => DateTime.to_iso8601(@sent_at)
    }

    Dispatcher.configure(self(), [{:ok, result}])
    {:ok, owner} = Owner.start_link(self())
    {:ok, client} = start_client(owner)
    channel = receive_channel()
    query = query()

    ClientFakeSocket.channel_message(client, channel, sync_payload(query))

    assert_receive {:dispatch, %Envelope{request_id: request_id}, _dispatcher_opts}
    assert request_id == query.envelope.request_id
    {_payload, %Result{value: ^result}} = receive_message(channel, Result)
    refute_receive {:dispatch, _, _}
  end

  test "production Dispatcher rejects Query without a false runtime or journal claim" do
    {:ok, owner} = Owner.start_link(self())

    {:ok, client} =
      start_client(owner,
        dispatcher: YellowDog.ServerAgent.Dispatcher,
        dispatcher_runtime_adapter: Dispatcher
      )

    channel = receive_channel()
    ClientFakeSocket.channel_message(client, channel, sync_payload(query()))

    {_payload, %Result{value: nil, error: %Error{code: :invalid}}} =
      receive_message(channel, Result)

    refute_receive {:dispatch, _, _}
    refute_receive {:journal_call, _}
  end

  test "routes ConfigDelivery once and publishes returned evidence" do
    publication = config_publication(1, :delivered)

    ClientFakeSocket.set_pushes(
      List.duplicate({:ok, %{"accepted" => true}}, 3) ++ [{:ok, receipt(publication, 1)}]
    )

    {:ok, owner} =
      Owner.start_link(self(),
        apply_replies: [{:ok, %{status: :applied, publications: [publication]}}]
      )

    {:ok, client} = start_client(owner)
    channel = receive_channel()
    delivery = config_delivery()
    ClientFakeSocket.channel_message(client, channel, sync_payload(delivery))

    assert_receive {:config_apply, %Envelope{request_id: request_id}}
    assert request_id == delivery.envelope.request_id
    assert_receive {:acknowledge_publication, 1}
    refute_receive {:config_apply, _}
  end

  test "rejects malformed, noncanonical, unsupported, cross-ID, and non-sync input" do
    Dispatcher.configure(self(), [{:ok, %{"service" => "dns", "state" => "running"}}])
    {:ok, owner} = Owner.start_link(self())
    {:ok, client} = start_client(owner)
    channel = receive_channel()

    malformed = %{"message" => "{", "publication_sequence" => nil}

    unsupported =
      sync_payload(%Heartbeat{target_type: :server, target_id: @server_id, observed_at: @sent_at})

    cross_id = command(target_id: "server-west-1") |> sync_payload()
    canonical = command() |> sync_payload()
    noncanonical = %{canonical | "message" => String.replace(canonical["message"], ":", ": ")}

    for payload <- [malformed, unsupported, cross_id, noncanonical] do
      ClientFakeSocket.channel_message(client, channel, payload)
    end

    ClientFakeSocket.channel_message(client, channel, "other", canonical)
    refute_receive {:dispatch, _, _}
    refute_receive {:config_apply, _}
  end

  test "ignores old channel messages and late disconnects after rejoin" do
    Dispatcher.configure(self(), [{:ok, %{"service" => "dns", "state" => "running"}}])
    {:ok, owner} = Owner.start_link(self())
    {:ok, client} = start_client(owner)
    old_channel = receive_channel()
    Process.exit(old_channel, :shutdown)
    assert_receive {:timer_scheduled, ^client, {:rejoin, 1}, 100, _ref}
    send(client, {:rejoin, 1})
    new_channel = receive_channel()

    ClientFakeSocket.channel_message(client, old_channel, sync_payload(command()))
    send(client, {:DOWN, make_ref(), :process, old_channel, :late})
    refute_receive {:dispatch, _, _}
    assert Client.connected?(client)

    ClientFakeSocket.channel_message(client, new_channel, sync_payload(command()))
    assert_receive {:dispatch, _, _}
  end

  test "publishes canonical heartbeat and status on generation-bound timers" do
    {:ok, owner} = Owner.start_link(self())
    {:ok, client} = start_client(owner)
    channel = receive_channel()

    assert_receive {:timer_scheduled, ^client, {:heartbeat, generation}, 1_000, _ref}
    assert_receive {:timer_scheduled, ^client, {:status, ^generation}, 2_000, _ref}

    send(client, {:heartbeat, generation})
    {_payload, %Heartbeat{target_id: @server_id}} = receive_message(channel, Heartbeat)

    send(client, {:status, generation})
    {_payload, %Status{target_id: @server_id, state: :online}} = receive_message(channel, Status)
  end

  test "disconnect cleanup ignores late messages and follows exact bounded backoff reset" do
    ClientFakeSocket.configure(self(), joins: [:ok, {:error, :join_failed}, :ok])
    {:ok, owner} = Owner.start_link(self())
    {:ok, client} = start_client(owner, initial_backoff: 100, max_backoff: 200)
    first_channel = receive_channel()

    Process.exit(first_channel, :shutdown)
    assert_receive {:timer_scheduled, ^client, {:rejoin, 1}, 100, _ref}
    send(client, {:rejoin, 1})
    assert_receive {:timer_scheduled, ^client, {:rejoin, 2}, 200, _ref}
    send(client, {:rejoin, 2})
    second_channel = receive_channel()
    assert Client.connected?(client)

    Process.exit(second_channel, :shutdown)
    assert_receive {:timer_scheduled, ^client, {:rejoin, 1}, 100, _ref}
  end

  test "bounds socket connection polling with the injected monotonic clock" do
    ClientFakeSocket.configure(self(), connected: false)
    ClientFakeMonotonicClock.configure([0, 299, 300])
    {:ok, owner} = Owner.start_link(self())
    {:ok, client} = start_client(owner)

    assert_receive {:timer_scheduled, ^client, {:check_socket, connection_id}, 10, _ref}
    send(client, {:check_socket, connection_id})
    assert_receive {:timer_scheduled, ^client, {:check_socket, ^connection_id}, 10, _ref}

    send(client, {:check_socket, connection_id})
    assert_receive {:timer_scheduled, ^client, {:rejoin, 1}, 100, _ref}
    assert Client.connection_state(client) == :backoff
    refute_receive {:socket_join, _, _, _, _}
  end

  test "public inspection and logs never expose token" do
    {:ok, owner} = Owner.start_link(self())
    {:ok, active_client} = start_client(owner)
    active_state = :sys.get_state(active_client)
    refute contains_secret?(active_state, @token)
    refute inspect(active_state) =~ @token
    assert active_state.socket == active_state.config.credential_ref

    assert {:timeout, {:sys, :get_state, _arguments}} =
             catch_exit(:sys.get_state(active_state.socket, 10))

    GenServer.stop(active_client, :normal)

    ClientFakeSocket.set_starts([{:error, {:auth, @token}}])
    {:ok, failed_owner} = Owner.start_link(self())

    log =
      capture_log(fn ->
        {:ok, client} = start_client(failed_owner)
        refute Client.connected?(client)
        assert Client.connection_state(client) == :backoff
        failed_state = :sys.get_state(client)
        refute contains_secret?(failed_state, @token)
        refute inspect(failed_state) =~ @token
      end)

    refute log =~ @token
    refute inspect(Client.connection_state(unique_name())) =~ @token
  end

  test "opaque credential reference rejects calls outside its bound Client" do
    {:ok, owner} = Owner.start_link(self())
    {:ok, client} = start_client(owner)
    assert_receive {:socket_start, _initial_opts}
    credential_ref = :sys.get_state(client).config.credential_ref

    assert :error =
             Client.CredentialProvider.start_link(
               url: "wss://attacker.example.test/server/ws/websocket",
               credential_ref: credential_ref
             )

    refute_receive {:socket_start,
                    [url: "wss://attacker.example.test/server/ws/websocket", params: _params]}

    assert Client.connected?(client)
  end

  defp start_client(owner, overrides \\ []) do
    Client.start_link(Keyword.merge(base_opts(owner), overrides))
  end

  defp base_opts(owner) do
    [
      enabled: true,
      name: nil,
      management_url: "https://management.example.test:4443/base",
      token: @token,
      identity: identity(),
      dispatcher: Dispatcher,
      dispatcher_runtime_adapter: Dispatcher,
      command_journal: owner,
      config_applier: owner,
      config_apply_store: owner,
      socket: ClientFakeSocket,
      timer: ClientFakeTimer,
      monotonic_clock: ClientFakeMonotonicClock,
      wall_clock: ClientFakeWallClock,
      connection_poll_interval: 10,
      connect_timeout: 300,
      join_timeout: 400,
      push_timeout: 500,
      heartbeat_interval: 1_000,
      status_interval: 2_000,
      initial_backoff: 100,
      max_backoff: 1_000
    ]
  end

  defp identity do
    %Server{
      id: @server_id,
      name: "Server East",
      version: "1.1.4",
      profile: "default",
      capabilities: ["runtime.services"],
      config_revision: @revision
    }
  end

  defp command(opts \\ []) do
    envelope =
      envelope(
        Keyword.merge(
          [
            request_id: "11111111-1111-4111-8111-111111111111",
            idempotency_key: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            operation: "server.runtime.services.start",
            payload: %{"service" => "dns"}
          ],
          opts
        )
      )

    %Command{envelope: envelope}
  end

  defp config_delivery do
    payload = %{"service" => "dns", "entries" => []}

    %ConfigDelivery{
      envelope:
        envelope(
          request_id: "22222222-2222-4222-8222-222222222222",
          idempotency_key: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
          operation: "server.settings.update",
          payload: payload,
          config_version: 1
        )
    }
  end

  defp query do
    %Query{
      envelope:
        envelope(
          request_id: "33333333-3333-4333-8333-333333333333",
          idempotency_key: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
          operation: "server.runtime.services.list",
          payload: %{}
        )
    }
  end

  defp envelope(opts) do
    payload = Keyword.fetch!(opts, :payload)

    %Envelope{
      protocol_version: 1,
      request_id: Keyword.fetch!(opts, :request_id),
      target_type: :server,
      target_id: Keyword.get(opts, :target_id, @server_id),
      operation: Keyword.fetch!(opts, :operation),
      expected_revision: nil,
      idempotency_key: Keyword.fetch!(opts, :idempotency_key),
      payload: payload,
      payload_digest: digest(payload),
      config_version: Keyword.get(opts, :config_version),
      sent_at: @sent_at
    }
  end

  defp config_publication(sequence, state) do
    message = %ConfigState{
      target_type: :server,
      target_id: @server_id,
      operation: "server.settings.update",
      state: state,
      version: 1,
      digest: digest(%{"service" => "dns", "entries" => []}),
      applied_revision: if(state == :applied, do: @revision),
      previous_version: nil,
      previous_revision: nil,
      failure: nil,
      rollback: nil,
      observed_at: @sent_at
    }

    {:ok, encoded_message} = Message.encode(message)
    %{sequence: sequence, encoded_message: encoded_message, message: message}
  end

  defp receipt(publication, state_revision) do
    %{
      "target_type" => "server",
      "target_id" => @server_id,
      "publication_sequence" => publication.sequence,
      "state_revision" => state_revision
    }
  end

  defp failed_publication(sequence, phase) do
    previous? = phase == "rollback"

    message = %ConfigState{
      target_type: :server,
      target_id: @server_id,
      operation: "server.settings.update",
      state: :failed,
      version: if(previous?, do: 2, else: 1),
      digest: digest(%{"service" => "dns", "entries" => []}),
      applied_revision: nil,
      previous_version: if(previous?, do: 1),
      previous_revision: if(previous?, do: @revision),
      failure: %{"phase" => phase, "reason" => phase <> " failed"},
      rollback:
        if(previous?,
          do: %{
            "succeeded" => false,
            "restored_version" => nil,
            "restored_revision" => nil,
            "reason" => "rollback failed"
          }
        ),
      observed_at: @sent_at
    }

    {:ok, encoded_message} = Message.encode(message)
    %{sequence: sequence, encoded_message: encoded_message, message: message}
  end

  defp sync_payload(message) do
    {:ok, encoded} = Message.encode(message)
    %{"message" => encoded, "publication_sequence" => nil}
  end

  defp decode_payload(%{"message" => encoded, "publication_sequence" => _sequence}) do
    Message.decode(encoded)
  end

  defp receive_channel do
    assert_receive {:socket_channel, channel}
    channel
  end

  defp receive_message(channel, module) do
    assert_receive {:socket_push, ^channel, "sync", payload, 500}
    assert {:ok, message} = decode_payload(payload)

    if message.__struct__ == module do
      {payload, message}
    else
      receive_message(channel, module)
    end
  end

  defp drain_activation(channel) do
    receive_message(channel, Hello)
    receive_message(channel, Status)
    receive_message(channel, Journal)
    :ok
  end

  defp unique_name do
    :"client_test_#{System.unique_integer([:positive, :monotonic])}"
  end

  defp digest(value) do
    {:ok, digest} = Digest.calculate(value)
    digest
  end

  defp contains_secret?(value, secret) when is_binary(value),
    do: String.contains?(value, secret)

  defp contains_secret?(value, secret) when is_function(value) do
    {:env, environment} = :erlang.fun_info(value, :env)
    contains_secret?(environment, secret)
  end

  defp contains_secret?(value, secret) when is_map(value) do
    value
    |> Map.to_list()
    |> Enum.any?(fn {key, item} ->
      contains_secret?(key, secret) or contains_secret?(item, secret)
    end)
  end

  defp contains_secret?(value, secret) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> contains_secret?(secret)
  end

  defp contains_secret?(value, secret) when is_list(value),
    do: Enum.any?(value, &contains_secret?(&1, secret))

  defp contains_secret?(_value, _secret), do: false
end
