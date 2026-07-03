defmodule Abyss.TableOwner do
  @moduledoc false
  # Owns the shared named ETS tables used across all Abyss server instances:
  #
  # - `:abyss_listener_info` - listener socket/endpoint cache (see
  #   `Abyss.Listener`)
  # - `:abyss_telemetry_metrics` - metrics counters (see `Abyss.Telemetry`)
  #
  # The tables are public; this process only ties their lifetime to the
  # `:abyss` application. All lazy `ensure_*` calls route table creation
  # through `ensure_table/2` so that no matter which process first needs a
  # table, it is created by (and owned by) this process rather than by a
  # transient server, listener, or handler process.

  use GenServer

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(arg) do
    GenServer.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @doc false
  # Ensure a named ETS table exists. When this process is running the table
  # is created here so it survives the caller's death; otherwise (the :abyss
  # application not started) it is created in the calling process as a
  # fallback.
  @spec ensure_table(atom(), list()) :: :ok
  def ensure_table(name, opts) do
    case :ets.whereis(name) do
      :undefined ->
        case Process.whereis(__MODULE__) do
          nil -> create_table(name, opts)
          pid when pid == self() -> create_table(name, opts)
          _pid -> GenServer.call(__MODULE__, {:ensure_table, name, opts})
        end

      _ref ->
        :ok
    end
  end

  @impl GenServer
  def init(_arg) do
    Abyss.Listener.ensure_info_table_exists()
    Abyss.Telemetry.init_metrics()
    {:ok, %{}}
  end

  @impl GenServer
  def handle_call({:ensure_table, name, opts}, _from, state) do
    {:reply, create_table(name, opts), state}
  end

  defp create_table(name, opts) do
    :ets.new(name, opts)
    :ok
  rescue
    # Concurrent creation race - the table already exists
    ArgumentError -> :ok
  end
end
