defmodule YellowDog.ServerAgent.Heartbeat do
  @moduledoc """
  Local heartbeat state for the server agent skeleton.

  The process does not make network calls. It only keeps local status that a
  future sync process can publish to management core.
  """

  use GenServer

  alias YellowDog.Sync.Bounds

  @connection_states [:disabled, :connecting, :handshaking, :active, :backoff, :unavailable]
  @allowed_options [:name, :agent_id, :connection_state]

  @enforce_keys [:agent_id, :started_at, :last_heartbeat_at, :connection_state]
  defstruct [:agent_id, :started_at, :last_heartbeat_at, :connection_state, status: :idle]

  @type t :: %__MODULE__{
          agent_id: String.t(),
          status: atom(),
          started_at: DateTime.t(),
          last_heartbeat_at: DateTime.t(),
          connection_state:
            :disabled | :connecting | :handshaking | :active | :backoff | :unavailable
        }

  def start_link(opts \\ []) do
    with {:ok, config, name} <- validate_options(opts) do
      GenServer.start_link(__MODULE__, config, name: name)
    end
  end

  def snapshot(server \\ __MODULE__) do
    GenServer.call(server, :snapshot)
  end

  def heartbeat(server \\ __MODULE__) do
    GenServer.call(server, :heartbeat)
  end

  @doc false
  def record_connection_state(server \\ __MODULE__, connection_state) do
    if connection_state in @connection_states do
      GenServer.call(server, {:record_connection_state, connection_state})
    else
      {:error, :invalid_connection_state}
    end
  end

  @impl GenServer
  def init(config) do
    now = DateTime.utc_now(:second)

    {:ok,
     %__MODULE__{
       agent_id: config.agent_id,
       started_at: now,
       last_heartbeat_at: now,
       connection_state: config.connection_state
     }}
  end

  @impl GenServer
  def handle_call(:snapshot, _from, state) do
    {:reply, state, state}
  end

  def handle_call(:heartbeat, _from, state) do
    state = %{state | last_heartbeat_at: DateTime.utc_now(:second)}
    {:reply, {:ok, state}, state}
  end

  def handle_call({:record_connection_state, connection_state}, _from, state)
      when connection_state in @connection_states do
    {:reply, :ok, %{state | connection_state: connection_state}}
  end

  defp validate_options(opts) do
    with true <- is_list(opts) and Keyword.keyword?(opts),
         keys = Keyword.keys(opts),
         true <- Enum.all?(keys, &(&1 in @allowed_options)),
         true <- length(keys) == length(Enum.uniq(keys)),
         {:ok, name} <- process_name(Keyword.get(opts, :name, __MODULE__)),
         {:ok, agent_id} <- agent_id(Keyword.get(opts, :agent_id, "server-local")),
         {:ok, connection_state} <-
           connection_state(Keyword.get(opts, :connection_state, :disabled)) do
      {:ok, %{agent_id: agent_id, connection_state: connection_state}, name}
    else
      _invalid -> {:error, :invalid_options}
    end
  end

  defp process_name(value) when is_atom(value) and not is_nil(value), do: {:ok, value}
  defp process_name({:global, _term} = value), do: {:ok, value}

  defp process_name({:via, module, _term} = value)
       when is_atom(module) and not is_nil(module),
       do: {:ok, value}

  defp process_name(_value), do: :error

  defp agent_id(value) do
    with {:ok, value} <- Bounds.id(value),
         true <- value != "" do
      {:ok, value}
    else
      _invalid -> :error
    end
  end

  defp connection_state(value) when value in @connection_states, do: {:ok, value}
  defp connection_state(_value), do: :error
end
