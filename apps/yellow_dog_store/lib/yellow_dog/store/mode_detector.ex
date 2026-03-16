defmodule YellowDog.Store.ModeDetector do
  @moduledoc """
  GenServer responsible for:

  1. Detecting whether the node is operating alone or in a cluster.
  2. Setting the active `YellowDog.Store.Backend` via `persistent_term`.
  3. Creating and owning the ETS table used by `Backend.Ets`.
  4. Periodically sweeping expired ETS entries (write-heavy keys that are
     never read would otherwise leak memory indefinitely).

  Mode is checked every 30 seconds. When peers join or leave, the active
  backend switches automatically and a log entry is emitted.
  """

  use GenServer
  require Logger

  alias YellowDog.Store.Backend
  alias YellowDog.Store.Backend.Ets, as: EtsBackend

  @check_interval_ms 30_000
  @sweep_interval_ms 60_000

  defstruct mode: :single_node, peer_count: 0

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns the current mode: :single_node or :cluster."
  @spec mode() :: :single_node | :cluster
  def mode do
    case Backend.active() do
      EtsBackend -> :single_node
      _ -> :cluster
    end
  end

  @doc "Returns true if the Store is operating in single-node (ETS) mode."
  @spec single_node?() :: boolean()
  def single_node?, do: mode() == :single_node

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    EtsBackend.create_table()
    mode = detect_mode()
    Backend.set_active(backend_for(mode))
    schedule_check()
    schedule_sweep()
    {:ok, %__MODULE__{mode: mode, peer_count: peer_count()}}
  end

  @impl true
  def handle_info(:check_peers, state) do
    new_mode = detect_mode()
    old_mode = state.mode

    if new_mode != old_mode do
      Logger.info("Store mode changed: #{old_mode} -> #{new_mode}")
      Backend.set_active(backend_for(new_mode))
    end

    schedule_check()
    {:noreply, %{state | mode: new_mode, peer_count: peer_count()}}
  end

  def handle_info(:sweep_expired, state) do
    if state.mode == :single_node do
      _count = EtsBackend.sweep_expired()
    end

    schedule_sweep()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Private ---

  defp detect_mode do
    if peer_count() > 0, do: :cluster, else: :single_node
  end

  defp peer_count, do: length(Node.list())

  defp backend_for(:single_node), do: EtsBackend
  defp backend_for(:cluster), do: YellowDog.Store.Backend.Cluster

  defp schedule_check do
    Process.send_after(self(), :check_peers, @check_interval_ms)
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep_expired, @sweep_interval_ms)
  end
end
