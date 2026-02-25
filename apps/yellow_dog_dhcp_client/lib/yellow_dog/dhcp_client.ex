defmodule YellowDog.DhcpClient do
  @moduledoc """
  DHCP client for Yellow Dog.

  Manages the full DHCPv4 lifecycle per interface: DORA handshake, lease renewal,
  OS-level address/route/DNS configuration, and Yellow Dog vendor option exchange.

  Each interface runs its own supervised state machine. Use this module as the
  public API for starting, stopping, and querying DHCP client instances.
  """

  alias YellowDog.DhcpClient.{Application, LeaseStore, StateMachine}

  @registry YellowDog.DhcpClient.Registry

  @doc """
  Starts a DHCP client for the given network interface.

  ## Options

    * `:mode` - Operating mode, `:standalone` or `:hook` (default: `:standalone`)
    * `:hostname` - Hostname to send in Option 12
    * `:vendor_class` - Vendor class string (default: `"YellowDog"`)
    * `:capabilities` - List of capability atoms, e.g. `[:dns, :telemetry]`
    * `:selection_window_ms` - Offer selection window in ms (default: `1000`)
    * `:dad_enabled` - Enable duplicate address detection (default: `true`)

  ## Returns

    * `{:ok, pid}` on success
    * `{:error, :already_started}` if a client for this interface is running
    * `{:error, reason}` on failure
  """
  @spec start_interface(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_interface(interface, opts \\ []) when is_binary(interface) do
    case lookup(interface) do
      {:ok, _pid} ->
        {:error, :already_started}

      :error ->
        Application.start_interface(interface, opts)
    end
  end

  @doc """
  Stops the DHCP client for the given network interface.

  Sends DHCPRELEASE if currently bound, then terminates the interface supervisor.

  ## Returns

    * `:ok` on success
    * `{:error, :not_found}` if no client is running for this interface
  """
  @spec stop_interface(String.t()) :: :ok | {:error, :not_found}
  def stop_interface(interface) when is_binary(interface) do
    case lookup(interface) do
      {:ok, pid} ->
        Application.stop_interface(pid)

      :error ->
        {:error, :not_found}
    end
  end

  @doc """
  Returns the current lease for the given interface, or `nil` if no lease is held.
  """
  @spec lease(String.t()) :: YellowDog.DhcpClient.Lease.t() | nil
  def lease(interface) when is_binary(interface) do
    case lookup(interface) do
      {:ok, _pid} ->
        store = {:via, Registry, {@registry, {:store, interface}}}

        case LeaseStore.lookup(store, interface) do
          {:ok, lease} -> lease
          :not_found -> nil
        end

      :error ->
        nil
    end
  end

  @doc """
  Sends a DHCPRELEASE for the given interface and returns to INIT state.

  ## Returns

    * `:ok` on success
    * `{:error, :not_found}` if no client is running
    * `{:error, :not_bound}` if the client has no active lease
  """
  @spec release(String.t()) :: :ok | {:error, term()}
  def release(interface) when is_binary(interface) do
    case lookup(interface) do
      {:ok, _pid} ->
        fsm = {:via, Registry, {@registry, {:fsm, interface}}}
        StateMachine.release(fsm)

      :error ->
        {:error, :not_found}
    end
  end

  @doc """
  Returns the current FSM state for the given interface.

  Possible states: `:init`, `:selecting`, `:requesting`, `:bound`,
  `:renewing`, `:rebinding`.

  ## Returns

    * The current state atom
    * `{:error, :not_found}` if no client is running
  """
  @spec status(String.t()) :: atom() | {:error, :not_found}
  def status(interface) when is_binary(interface) do
    case lookup(interface) do
      {:ok, _pid} ->
        fsm = {:via, Registry, {@registry, {:fsm, interface}}}
        {state, _data} = StateMachine.status(fsm)
        state

      :error ->
        {:error, :not_found}
    end
  end

  @doc false
  def registry_name, do: @registry

  defp lookup(interface) do
    case Registry.lookup(@registry, {:interface_sup, interface}) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end
end
