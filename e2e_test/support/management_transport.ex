defmodule E2ETest.ManagementTransport do
  @moduledoc false

  use GenServer

  @behaviour YellowDog.Management.Transport

  alias YellowDog.ManagementCore
  alias YellowDog.NetmanAgent.CommandJournal, as: NetmanCommandJournal
  alias YellowDog.NetmanAgent.Dispatcher, as: NetmanDispatcher
  alias YellowDog.NetmanAgent.QueryDispatcher, as: NetmanQueryDispatcher
  alias YellowDog.ServerAgent.CommandJournal, as: ServerCommandJournal
  alias YellowDog.ServerAgent.ConfigApplier, as: ServerConfigApplier
  alias YellowDog.ServerAgent.ConfigApplyStore, as: ServerConfigApplyStore
  alias YellowDog.ServerAgent.Dispatcher, as: ServerDispatcher
  alias YellowDog.ServerAgent.QueryDispatcher, as: ServerQueryDispatcher
  alias YellowDog.Sync.Envelope
  alias YellowDog.Sync.Error
  alias YellowDog.Sync.Operation

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def connect(target_type, target_id) do
    with {:ok, endpoint} <- GenServer.call(__MODULE__, {:connect, target_type, target_id}),
         {:ok, journal} <- journal(target_type, endpoint.command_journal),
         {:ok, connection} <- ManagementCore.runtime_connected(target_type, target_id, journal),
         :ok <- maybe_deliver(connection.pending_config) do
      {:ok, connection}
    end
  end

  def disconnect(target_type, target_id) do
    :ok = GenServer.call(__MODULE__, {:disconnect, target_type, target_id})
    ManagementCore.runtime_disconnected(target_type, target_id)
  end

  def requests, do: GenServer.call(__MODULE__, :requests)
  def deliveries, do: GenServer.call(__MODULE__, :deliveries)

  def request_count(kind) when kind in [:query, :command] do
    Enum.count(requests(), &(&1.kind == kind))
  end

  @impl true
  def connected?(target_type, target_id) do
    GenServer.call(__MODULE__, {:connected?, target_type, target_id})
  end

  @impl true
  def request(%Envelope{} = envelope, timeout) do
    GenServer.call(__MODULE__, {:request, envelope, timeout}, timeout)
  catch
    :exit, {:timeout, _reason} ->
      {:error, Error.new(:timeout, "transport request timed out", %{})}
  end

  @impl true
  def deliver_config(%Envelope{} = envelope) do
    GenServer.call(__MODULE__, {:deliver_config, envelope}, :infinity)
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       server: Keyword.fetch!(opts, :server),
       netman: Keyword.fetch!(opts, :netman),
       connected: MapSet.new(),
       requests: [],
       deliveries: []
     }}
  end

  @impl true
  def handle_call({:connect, target_type, target_id}, _from, state) do
    case endpoint(state, target_type, target_id) do
      {:ok, endpoint} ->
        connected = MapSet.put(state.connected, {target_type, target_id})
        {:reply, {:ok, endpoint}, %{state | connected: connected}}

      {:error, %Error{}} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:disconnect, target_type, target_id}, _from, state) do
    connected = MapSet.delete(state.connected, {target_type, target_id})
    {:reply, :ok, %{state | connected: connected}}
  end

  def handle_call({:connected?, target_type, target_id}, _from, state) do
    {:reply, MapSet.member?(state.connected, {target_type, target_id}), state}
  end

  def handle_call(:requests, _from, state) do
    {:reply, Enum.reverse(state.requests), state}
  end

  def handle_call(:deliveries, _from, state) do
    {:reply, Enum.reverse(state.deliveries), state}
  end

  def handle_call({:request, envelope, timeout}, _from, state) do
    with {:ok, operation} <- Operation.lookup(envelope.operation),
         {:ok, endpoint} <- endpoint(state, envelope.target_type, envelope.target_id) do
      request = %{kind: operation.kind, envelope: envelope, timeout: timeout}
      result = dispatch(envelope, operation, endpoint)
      {:reply, result, %{state | requests: [request | state.requests]}}
    else
      {:error, %Error{}} = error -> {:reply, error, state}
    end
  end

  def handle_call({:deliver_config, envelope}, _from, state) do
    delivery = %{envelope: envelope}

    result =
      with {:ok, endpoint} <- endpoint(state, envelope.target_type, envelope.target_id),
           {:ok, _apply_result} <- apply_config(envelope, endpoint),
           :ok <- flush_publications(envelope.target_type, envelope.target_id, endpoint) do
        :ok
      end

    {:reply, result, %{state | deliveries: [delivery | state.deliveries]}}
  end

  defp dispatch(%Envelope{target_type: :server} = envelope, %Operation{kind: :query}, endpoint) do
    ServerQueryDispatcher.dispatch(
      envelope,
      server_id: endpoint.id,
      capabilities: endpoint.capabilities,
      runtime_adapter: E2ETest.ServerRuntime
    )
  end

  defp dispatch(%Envelope{target_type: :server} = envelope, %Operation{kind: :command}, endpoint) do
    ServerDispatcher.dispatch(
      envelope,
      server_id: endpoint.id,
      capabilities: endpoint.capabilities,
      command_journal: endpoint.command_journal,
      runtime_adapter: E2ETest.ServerRuntime
    )
  end

  defp dispatch(%Envelope{target_type: :netman} = envelope, %Operation{kind: :query}, endpoint) do
    NetmanQueryDispatcher.dispatch(
      envelope,
      netman_id: endpoint.id,
      capabilities: endpoint.capabilities,
      runtime_adapter: E2ETest.NetmanRuntime
    )
  end

  defp dispatch(%Envelope{target_type: :netman} = envelope, %Operation{kind: :command}, endpoint) do
    NetmanDispatcher.dispatch(
      envelope,
      netman_id: endpoint.id,
      capabilities: endpoint.capabilities,
      command_journal: endpoint.command_journal,
      runtime_adapter: E2ETest.NetmanRuntime
    )
  end

  defp dispatch(_envelope, _operation, _endpoint),
    do: {:error, Error.new(:unsupported, "unsupported operation", %{})}

  defp apply_config(%Envelope{target_type: :server} = envelope, endpoint) do
    ServerConfigApplier.apply(envelope, endpoint.config_applier)
  end

  defp apply_config(_envelope, _endpoint),
    do: {:error, Error.new(:unsupported, "unsupported config target", %{})}

  defp flush_publications(:server, target_id, endpoint) do
    with {:ok, publications} <-
           ServerConfigApplyStore.pending_publications(endpoint.config_apply_store),
         :ok <- publish_all(:server, target_id, publications, endpoint.config_apply_store) do
      if publications == [],
        do: :ok,
        else: flush_publications(:server, target_id, endpoint)
    end
  end

  defp publish_all(target_type, target_id, publications, apply_store) do
    Enum.reduce_while(publications, :ok, fn publication, :ok ->
      with {:ok, _receipt} <-
             ManagementCore.accept_config_state_publication(
               target_type,
               target_id,
               publication.sequence,
               publication.encoded_message
             ),
           {:ok, _snapshot} <-
             ServerConfigApplyStore.acknowledge_publication(publication.sequence, apply_store) do
        {:cont, :ok}
      else
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
  end

  defp journal(:server, command_journal),
    do: ServerCommandJournal.wire_projection(command_journal)

  defp journal(:netman, command_journal),
    do: NetmanCommandJournal.wire_projection(command_journal)

  defp maybe_deliver(nil), do: :ok

  defp maybe_deliver(version) do
    deliver_config(%Envelope{
      protocol_version: 1,
      request_id: uuid(),
      target_type: version.target_type,
      target_id: version.target_id,
      operation: version.operation,
      idempotency_key: uuid(),
      payload: version.payload,
      payload_digest: version.digest,
      expected_revision: version.expected_revision,
      config_version: version.version,
      sent_at: version.published_at
    })
  end

  defp endpoint(state, target_type, target_id) when target_type in [:server, :netman] do
    case Map.fetch!(state, target_type) do
      %{id: ^target_id} = endpoint -> {:ok, endpoint}
      _other -> {:error, Error.new(:not_found, "runtime endpoint not found", %{})}
    end
  end

  defp endpoint(_state, _target_type, _target_id),
    do: {:error, Error.new(:invalid, "invalid runtime endpoint", %{})}

  defp uuid do
    random = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

    String.slice(random, 0, 8) <>
      "-" <>
      String.slice(random, 8, 4) <>
      "-4" <>
      String.slice(random, 13, 3) <>
      "-8" <>
      String.slice(random, 17, 3) <>
      "-" <>
      String.slice(random, 20, 12)
  end
end

defmodule E2ETest.ServerRuntime do
  @moduledoc false

  use GenServer

  @behaviour YellowDog.ServerAgent.RuntimeAdapter

  alias YellowDog.Sync.Envelope
  alias YellowDog.Sync.Error

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  def active_revision, do: GenServer.call(__MODULE__, :active_revision)
  def command_calls, do: GenServer.call(__MODULE__, :command_calls)
  def rollback_calls, do: GenServer.call(__MODULE__, :rollback_calls)
  def fail_next_activation, do: GenServer.call(__MODULE__, :fail_next_activation)

  @impl true
  def validate_config(document), do: GenServer.call(__MODULE__, {:validate_config, document})

  @impl true
  def install_config(document, opts),
    do: GenServer.call(__MODULE__, {:install_config, document, opts})

  @impl true
  def activate_config(revision), do: GenServer.call(__MODULE__, {:activate_config, revision})

  @impl true
  def restore_config(revision), do: GenServer.call(__MODULE__, {:restore_config, revision})

  def dispatch(%Envelope{} = envelope), do: GenServer.call(__MODULE__, {:dispatch, envelope})

  @impl true
  def init(:ok) do
    {:ok,
     %{
       active_revision: nil,
       command_calls: 0,
       rollback_calls: 0,
       fail_next_activation?: false
     }}
  end

  @impl true
  def handle_call(:active_revision, _from, state),
    do: {:reply, state.active_revision, state}

  def handle_call(:command_calls, _from, state),
    do: {:reply, state.command_calls, state}

  def handle_call(:rollback_calls, _from, state),
    do: {:reply, state.rollback_calls, state}

  def handle_call(:fail_next_activation, _from, state),
    do: {:reply, :ok, %{state | fail_next_activation?: true}}

  def handle_call({:validate_config, document}, _from, state) when is_map(document),
    do: {:reply, :ok, state}

  def handle_call({:install_config, _document, opts}, _from, state) do
    {:reply, {:ok, Keyword.fetch!(opts, :digest)}, state}
  end

  def handle_call({:activate_config, _revision}, _from, %{fail_next_activation?: true} = state) do
    {:reply, {:error, :forced_activation_failure}, %{state | fail_next_activation?: false}}
  end

  def handle_call({:activate_config, revision}, _from, state) do
    {:reply, :ok, %{state | active_revision: revision}}
  end

  def handle_call({:restore_config, revision}, _from, state) do
    state = %{
      state
      | active_revision: revision,
        rollback_calls: state.rollback_calls + 1
    }

    {:reply, :ok, state}
  end

  def handle_call(
        {:dispatch, %Envelope{operation: "server.runtime.capabilities.get"}},
        _from,
        state
      ) do
    result = %{"capabilities" => ["runtime.capabilities", "runtime.services"]}
    {:reply, {:ok, result}, state}
  end

  def handle_call(
        {:dispatch, %Envelope{operation: "server.runtime.services.start", payload: payload}},
        _from,
        state
      ) do
    result = %{"service" => payload["service"], "state" => "running"}
    {:reply, {:ok, result}, %{state | command_calls: state.command_calls + 1}}
  end

  def handle_call({:dispatch, _envelope}, _from, state) do
    {:reply, {:error, Error.new(:unsupported, "unsupported operation", %{})}, state}
  end
end

defmodule E2ETest.NetmanRuntime do
  @moduledoc false

  alias YellowDog.Sync.Envelope
  alias YellowDog.Sync.Error

  def dispatch(%Envelope{operation: "netman.runtime.capabilities.get"}) do
    {:ok, %{"capabilities" => ["runtime.capabilities"]}}
  end

  def dispatch(_envelope),
    do: {:error, Error.new(:unsupported, "unsupported operation", %{})}
end
