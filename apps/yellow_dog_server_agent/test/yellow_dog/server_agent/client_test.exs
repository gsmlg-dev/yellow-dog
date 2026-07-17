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
         apply_replies: Keyword.get(opts, :apply_replies, [])
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
      publications = Enum.reject(state.publications, &(&1.sequence == sequence))
      {:reply, {:ok, %{outbox: publications}}, %{state | publications: publications}}
    end

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
    invalid = [
      [],
      [enabled: true],
      Keyword.delete(base_opts(), :token),
      Keyword.delete(base_opts(), :identity),
      Keyword.put(base_opts(), :management_url, "http://management.example.test"),
      Keyword.put(base_opts(), :management_url, "wss://management.example.test"),
      Keyword.put(base_opts(), :token, ""),
      Keyword.put(base_opts(), :identity, %{id: @server_id}),
      Keyword.put(base_opts(), :heartbeat_interval, 0),
      Keyword.put(base_opts(), :initial_backoff, 2_000),
      Keyword.put(base_opts(), :unknown, true),
      base_opts() ++ [token: "duplicate"]
    ]

    for opts <- invalid do
      assert {:error, :invalid_options} = Client.start_link(opts)
    end

    assert {:error, :invalid_options} = Client.start_link(:invalid)
    assert {:error, :invalid_options} = Client.start_link(enabled: false, token: @token)
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

    send(client, {:flush_config, generation})
    assert_receive {:acknowledge_publication, 1}
    refute_receive {:config_apply, _envelope}
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
    refute inspect(:sys.get_state(active_client)) =~ @token
    GenServer.stop(active_client, :normal)

    ClientFakeSocket.set_pushes([{:error, {:auth, @token}}])
    {:ok, failed_owner} = Owner.start_link(self())

    log =
      capture_log(fn ->
        {:ok, client} = start_client(failed_owner)
        refute Client.connected?(client)
        assert Client.connection_state(client) == :backoff
        refute inspect(:sys.get_state(client)) =~ @token
      end)

    refute log =~ @token
    refute inspect(Client.connection_state(unique_name())) =~ @token
  end

  defp start_client(owner, overrides \\ []) do
    Client.start_link(Keyword.merge(base_opts(owner), overrides))
  end

  defp base_opts(owner \\ unique_name()) do
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
end
