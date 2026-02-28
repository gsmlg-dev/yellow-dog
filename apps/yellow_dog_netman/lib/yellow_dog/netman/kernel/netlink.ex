defmodule YellowDog.Netman.Kernel.Netlink do
  @moduledoc """
  GenServer owning the Rust netlink port process.

  Receives kernel network events (link/address/route changes) and dispatches
  commands (add/remove addresses, routes, set link state).

  Protocol: 4-byte length prefix + JSON payload over stdin/stdout.

  In test mode, uses a mock backend instead of the actual port.
  """

  use GenServer

  require Logger

  @type event ::
          {:link_change, map()}
          | {:address_change, map()}
          | {:route_change, map()}
          | {:rule_change, map()}
          | {:neighbor_change, map()}

  defstruct [:port, :backend, subscribers: []]

  ## Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Send a command to the netlink port."
  @spec command(map()) :: :ok | {:error, term()}
  def command(cmd) when is_map(cmd) do
    GenServer.call(__MODULE__, {:command, cmd})
  end

  @doc "Subscribe the current process to netlink events."
  @spec subscribe() :: :ok
  def subscribe do
    GenServer.cast(__MODULE__, {:subscribe, self()})
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
    json = Jason.encode!(cmd)
    send(port, {self(), {:command, json}})
    {:reply, :ok, state}
  end

  def handle_call({:command, _cmd}, _from, state) do
    {:reply, {:error, :not_connected}, state}
  end

  @impl true
  def handle_cast({:subscribe, pid}, state) do
    ref = Process.monitor(pid)
    {:noreply, %{state | subscribers: [{pid, ref} | state.subscribers]}}
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
    Logger.warning("Netlink port closed unexpectedly, running in degraded mode")
    {:noreply, %{state | port: nil}}
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
    parsed = parse_event(event)

    for {pid, _ref} <- subscribers do
      send(pid, {:netlink_event, parsed})
    end
  end

  defp parse_event(%{"type" => "link_change"} = e), do: {:link_change, e}
  defp parse_event(%{"type" => "address_change"} = e), do: {:address_change, e}
  defp parse_event(%{"type" => "route_change"} = e), do: {:route_change, e}
  defp parse_event(%{"type" => "rule_change"} = e), do: {:rule_change, e}
  defp parse_event(%{"type" => "neighbor_change"} = e), do: {:neighbor_change, e}
  defp parse_event(e), do: {:unknown, e}
end
