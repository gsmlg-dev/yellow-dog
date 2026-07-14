defmodule YellowDog.ServerAgent.Heartbeat do
  @moduledoc """
  Local heartbeat state for the server agent skeleton.

  The process does not make network calls. It only keeps local status that a
  future sync process can publish to management core.
  """

  use GenServer

  @enforce_keys [:agent_id, :started_at, :last_heartbeat_at]
  defstruct [:agent_id, :started_at, :last_heartbeat_at, status: :idle]

  @type t :: %__MODULE__{
          agent_id: String.t(),
          status: atom(),
          started_at: DateTime.t(),
          last_heartbeat_at: DateTime.t()
        }

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def snapshot(server \\ __MODULE__) do
    GenServer.call(server, :snapshot)
  end

  def heartbeat(server \\ __MODULE__) do
    GenServer.call(server, :heartbeat)
  end

  @impl GenServer
  def init(opts) do
    now = DateTime.utc_now(:second)

    {:ok,
     %__MODULE__{
       agent_id: Keyword.get(opts, :agent_id, "server-local"),
       started_at: now,
       last_heartbeat_at: now
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
end
