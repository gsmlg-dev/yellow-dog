defmodule YellowDog.DhcpClient.Application do
  @moduledoc """
  Application module for the Yellow Dog DHCP client.

  Starts the supervision tree:

      Application
      ├── Registry  (named: YellowDog.DhcpClient.Registry)
      ├── DynamicSupervisor  (named: YellowDog.DhcpClient.DynamicSupervisor)
      └── ConfigWatcher

  The `DynamicSupervisor` manages per-interface `InterfaceSupervisor` children.
  Each interface gets its own supervision subtree with a socket, state machine,
  lease store, and OS integration process.
  """

  use Application

  require Logger

  @dynamic_supervisor YellowDog.DhcpClient.DynamicSupervisor

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: YellowDog.DhcpClient.Registry},
      {DynamicSupervisor, name: @dynamic_supervisor, strategy: :one_for_one},
      {YellowDog.DhcpClient.ConfigWatcher, []}
    ]

    opts = [strategy: :one_for_one, name: YellowDog.DhcpClient.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @doc """
  Starts an InterfaceSupervisor for the given interface under the DynamicSupervisor.

  Called by `YellowDog.DhcpClient.start_interface/2` and `ConfigWatcher`.

  ## Options

  See `YellowDog.DhcpClient.start_interface/2`.
  """
  @spec start_interface(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_interface(interface, opts \\ []) do
    with {:ok, opts} <- resolve_mac(interface, opts) do
      spec = {YellowDog.DhcpClient.InterfaceSupervisor, [interface: interface] ++ opts}

      case DynamicSupervisor.start_child(@dynamic_supervisor, spec) do
        {:ok, pid} ->
          Logger.info("DHCP client interface supervisor started for #{interface}")
          {:ok, pid}

        {:error, {:already_started, pid}} ->
          {:error, {:already_started, pid}}

        {:error, reason} = error ->
          Logger.warning("Failed to start DHCP client for #{interface}: #{inspect(reason)}")
          error
      end
    end
  end

  defp resolve_mac(interface, opts) when is_list(opts) do
    if Keyword.has_key?(opts, :mac) do
      {:ok, opts}
    else
      case YellowDog.DhcpClient.read_mac(interface) do
        {:ok, mac} ->
          {:ok, Keyword.put(opts, :mac, mac)}

        {:error, reason} ->
          Logger.warning(
            "DHCP client: could not auto-detect MAC for #{interface}: #{inspect(reason)}"
          )

          {:error, {:mac_detection_failed, reason}}
      end
    end
  end

  @doc """
  Stops the InterfaceSupervisor for the given interface.
  """
  @spec stop_interface(pid()) :: :ok | {:error, :not_found}
  def stop_interface(pid) when is_pid(pid) do
    case DynamicSupervisor.terminate_child(@dynamic_supervisor, pid) do
      :ok -> :ok
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc false
  def dynamic_supervisor, do: @dynamic_supervisor
end
