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

  If the client has no active lease the release is a no-op (returns `:ok`).

  ## Returns

    * `:ok` on success or when no lease is held
    * `{:error, :not_found}` if no client is running for this interface
  """
  @spec release(String.t()) :: :ok | {:error, :not_found}
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

        try do
          {state, _data} = StateMachine.status(fsm)
          state
        catch
          # Registry entry exists but process has already terminated
          :exit, {:noproc, _} -> {:error, :not_found}
        end

      :error ->
        {:error, :not_found}
    end
  end

  @doc """
  Reads the MAC address of the given network interface.

  Returns a 6-byte binary on success.

  ## Examples

      iex> {:ok, mac} = YellowDog.DhcpClient.read_mac("eth0")
      iex> byte_size(mac)
      6
  """
  @spec read_mac(String.t()) :: {:ok, binary()} | {:error, term()}
  def read_mac(interface) when is_binary(interface) do
    case read_mac_sysfs(interface) do
      {:ok, _mac} = ok -> ok
      {:error, _} -> read_mac_ifconfig(interface)
    end
  end

  @doc false
  def registry_name, do: @registry

  defp read_mac_sysfs(interface) do
    path = "/sys/class/net/#{interface}/address"

    case File.read(path) do
      {:ok, content} ->
        parse_mac_string(String.trim(content))

      {:error, reason} ->
        {:error, {:read_mac, interface, reason}}
    end
  end

  defp read_mac_ifconfig(interface) do
    try do
      case System.cmd("ifconfig", [interface], stderr_to_stdout: true) do
        {output, 0} ->
          case Regex.run(~r/(?:ether|HWaddr)\s+([0-9a-fA-F:]{17})/, output) do
            [_, mac_str] -> parse_mac_string(mac_str)
            nil -> {:error, {:read_mac, interface, :mac_not_found_in_ifconfig}}
          end

        {_output, _code} ->
          {:error, {:read_mac, interface, :ifconfig_failed}}
      end
    rescue
      e in ErlangError ->
        {:error, {:read_mac, interface, Exception.message(e)}}
    end
  end

  defp lookup(interface) do
    case Registry.lookup(@registry, {:interface_sup, interface}) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  defp parse_mac_string(mac_str) do
    parts = String.split(mac_str, [":", "-"])

    if length(parts) == 6 do
      bytes =
        Enum.map(parts, fn hex ->
          {byte, ""} = Integer.parse(hex, 16)
          byte
        end)

      {:ok, :binary.list_to_bin(bytes)}
    else
      {:error, {:invalid_mac, mac_str}}
    end
  rescue
    _ -> {:error, {:invalid_mac, mac_str}}
  end
end
