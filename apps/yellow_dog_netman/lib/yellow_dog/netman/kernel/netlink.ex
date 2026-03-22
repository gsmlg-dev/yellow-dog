defmodule YellowDog.Netman.Kernel.Netlink do
  @moduledoc """
  GenServer owning the Rust netlink port process.

  Receives kernel network events (link/address/route changes) and dispatches
  commands (add/remove addresses, routes, set link state).

  Protocol: 4-byte length prefix + JSON payload over stdin/stdout.

  In test mode, uses a mock backend instead of the actual port.
  """

  @compile {:no_warn_undefined, [Jason]}

  use GenServer

  require Logger

  @type event ::
          {:link_change, map()}
          | {:address_change, map()}
          | {:route_change, map()}
          | {:rule_change, map()}
          | {:neighbor_change, map()}

  @port_reconnect_base_ms 5_000
  @port_reconnect_max_ms 60_000

  defstruct [:port, :backend, subscribers: [], reconnect_attempts: 0]

  ## Client API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Send a command to the netlink port."
  @spec command(map()) :: :ok | {:error, term()}
  def command(cmd) when is_map(cmd) do
    GenServer.call(__MODULE__, {:command, cmd}, 10_000)
  end

  @doc "Subscribe the current process to netlink events."
  @spec subscribe() :: :ok
  def subscribe do
    GenServer.cast(__MODULE__, {:subscribe, self()})
  end

  @doc """
  Request a full re-dump of kernel network state.

  Sends a "dump" command to the netlink helper port, which triggers
  RTM_GET* requests for links, addresses, routes, rules, and neighbors.
  The dump responses flow through the normal event pipeline, repopulating
  the kernel monitors' ETS tables.

  Useful after hot code reload to recover state without restarting the port.
  """
  @spec request_dump() :: :ok | {:error, term()}
  def request_dump do
    GenServer.call(__MODULE__, :request_dump, 10_000)
  end

  ## Server callbacks

  @impl true
  def init(_opts) do
    backend = Application.get_env(:yellow_dog_netman, :netlink_backend, :port)

    state =
      case backend do
        :port ->
          port = open_port()
          %__MODULE__{port: port, backend: :port}

        :mock ->
          %__MODULE__{port: nil, backend: :mock}

        module when is_atom(module) ->
          %__MODULE__{port: nil, backend: module}
      end

    {:ok, state}
  end

  @impl true
  def handle_call({:command, cmd}, _from, %{backend: :mock} = state) do
    Logger.debug("Mock netlink command: #{inspect(cmd)}")
    {:reply, :ok, state}
  end

  def handle_call({:command, cmd}, _from, %{backend: :port, port: port} = state)
      when port != nil do
    case Jason.encode(cmd) do
      {:ok, json} ->
        send(port, {self(), {:command, json}})
        {:reply, :ok, state}

      {:error, reason} ->
        Logger.error("Failed to encode netlink command: #{inspect(reason)}")
        {:reply, {:error, :encode_failed}, state}
    end
  end

  def handle_call({:command, _cmd}, _from, state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call(:request_dump, _from, %{backend: :port, port: port} = state)
      when port != nil do
    case Jason.encode(%{"cmd" => "dump"}) do
      {:ok, json} ->
        send(port, {self(), {:command, json}})
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:request_dump, _from, %{backend: :mock} = state) do
    Logger.debug("Mock netlink dump requested")
    {:reply, :ok, state}
  end

  def handle_call(:request_dump, _from, state) do
    {:reply, {:error, :not_connected}, state}
  end

  @impl true
  def handle_cast({:subscribe, pid}, state) do
    if Enum.any?(state.subscribers, fn {p, _} -> p == pid end) do
      {:noreply, state}
    else
      ref = Process.monitor(pid)
      {:noreply, %{state | subscribers: [{pid, ref} | state.subscribers]}}
    end
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    case Jason.decode(data) do
      {:ok, event} ->
        dispatch_event(event, state.subscribers)
        {:noreply, state}

      {:error, reason} ->
        Logger.warning("Failed to decode netlink event: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  def handle_info({port, :closed}, %{port: port} = state) do
    delay = reconnect_delay(0)

    Logger.warning("Netlink port closed unexpectedly, scheduling reconnect in #{delay}ms")

    Process.send_after(self(), :reconnect_port, delay)
    {:noreply, %{state | port: nil, reconnect_attempts: 1}}
  end

  def handle_info(:reconnect_port, %{backend: :port, port: nil} = state) do
    case open_port() do
      nil ->
        delay = reconnect_delay(state.reconnect_attempts)

        Logger.warning(
          "Port reconnect failed (attempt #{state.reconnect_attempts}), retrying in #{delay}ms"
        )

        Process.send_after(self(), :reconnect_port, delay)
        {:noreply, %{state | reconnect_attempts: state.reconnect_attempts + 1}}

      port ->
        Logger.info("Netlink port reconnected successfully")
        {:noreply, %{state | port: port, reconnect_attempts: 0}}
    end
  end

  def handle_info(:reconnect_port, state) do
    # Port already reconnected or not in port mode — ignore
    {:noreply, state}
  end

  def handle_info({:mock_event, event}, state) do
    dispatch_event(event, state.subscribers)
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    subscribers = Enum.reject(state.subscribers, fn {_p, r} -> r == ref end)
    {:noreply, %{state | subscribers: subscribers}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{port: port} = _state) when port != nil do
    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  def terminate(_reason, _state), do: :ok

  ## Internal

  defp open_port do
    helper_path =
      Application.get_env(
        :yellow_dog_netman,
        :netlink_helper_path,
        Path.join(:code.priv_dir(:yellow_dog_netman), "native/netlink_helper")
      )

    if File.exists?(helper_path) do
      Port.open({:spawn_executable, helper_path}, [:binary, {:packet, 4}])
    else
      Logger.warning("Netlink helper not found at #{helper_path}, running in degraded mode")
      nil
    end
  end

  defp dispatch_event(event, subscribers) do
    case parse_event(event) do
      :command_error ->
        # Already logged in parse_event; don't broadcast to subscribers
        :ok

      parsed ->
        for {pid, _ref} <- subscribers do
          send(pid, {:netlink_event, parsed})
        end
    end
  end

  defp reconnect_delay(attempts) do
    min(@port_reconnect_base_ms * Bitwise.bsl(1, attempts), @port_reconnect_max_ms)
  end

  defp parse_event(%{"type" => "command_error", "cmd" => cmd, "error" => error}) do
    Logger.warning("Netlink command failed: #{cmd} — #{error}")
    :command_error
  end

  defp parse_event(%{"type" => "link_change"} = e), do: {:link_change, e}
  defp parse_event(%{"type" => "address_change"} = e), do: {:address_change, e}
  defp parse_event(%{"type" => "route_change"} = e), do: {:route_change, e}
  defp parse_event(%{"type" => "rule_change"} = e), do: {:rule_change, e}
  defp parse_event(%{"type" => "neighbor_change"} = e), do: {:neighbor_change, e}

  defp parse_event(e) do
    Logger.warning("Unknown netlink event type: #{inspect(Map.get(e, "type"))}")
    {:unknown, e}
  end
end
