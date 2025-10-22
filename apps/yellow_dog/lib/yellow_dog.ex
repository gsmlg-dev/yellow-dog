defmodule YellowDog do
  @moduledoc """
  YellowDog is a distributed DNS and DHCP server.

  This is the core application that provides:
  - Configuration management
  - Orchestration of protocol-specific applications
  - Public API for the YellowDog system
  """

  @banner_text "YellowDog DNS and DHCP Server"

  @doc false
  def banner do
    @banner_text
  end

  @doc false
  @spec child_spec(any()) :: Supervisor.child_spec()
  def child_spec(_opts) do
    %{
      id: {__MODULE__, make_ref()},
      start: {__MODULE__, :start_link, []},
      type: :supervisor,
      restart: :permanent
    }
  end

  @doc """
  Starts a `YellowDog` instance.
  """
  @spec start_link(any()) :: Supervisor.on_start()
  def start_link(_opts \\ []) do
    # The YellowDog application is started via the Application module
    # This function is provided for compatibility but doesn't start anything directly
    {:ok, self()}
  end

  @doc """
  Get configuration value
  """
  def get_config(name) do
    YellowDog.Config.get(name)
  end

  @doc """
  Get all configuration
  """
  def get_all_config do
    YellowDog.Config.get_all()
  end

  @doc """
  Gets the status of all services.

  ## Returns
  - Map of service statuses with detailed information

  ## Examples
      iex> YellowDog.get_all_status()
      %{
        dns: %{enabled: true, running: true, ...},
        mdns: %{enabled: true, running: true, ...},
        dhcpv4: %{enabled: false, running: false, ...},
        dhcpv6: %{enabled: false, running: false, ...}
      }
  """
  @spec get_all_status() :: %{atom() => map()}
  defdelegate get_all_status(), to: YellowDog.ServiceManager

  @doc """
  Gets the status of a specific service.

  ## Parameters
  - `service` - Service name (:dns, :mdns, :dhcpv4, :dhcpv6)

  ## Returns
  - Map with service status details

  ## Examples
      iex> YellowDog.get_service_status(:mdns)
      %{
        enabled: true,
        running: true,
        uptime: "1h 23m 45s",
        stats: %{...}
      }
  """
  @spec get_service_status(atom()) :: map()
  defdelegate get_service_status(service), to: YellowDog.ServiceManager

  @doc """
  Gets detailed statistics for a specific service.

  ## Parameters
  - `service` - Service name (:dns, :mdns, :dhcpv4, :dhcpv6)

  ## Returns
  - Map with service-specific statistics

  ## Examples
      iex> YellowDog.get_service_stats(:mdns)
      %{total_entries: 150, active_entries: 120, expired_entries: 30}

      iex> YellowDog.get_service_stats(:dhcpv4)
      %{total_leases: 50, active_leases: 45, expired_leases: 5}
  """
  @spec get_service_stats(atom()) :: map()
  defdelegate get_service_stats(service), to: YellowDog.ServiceManager

  @doc """
  Lists all available services.

  ## Returns
  - List of service atoms

  ## Examples
      iex> YellowDog.list_services()
      [:dns, :mdns, :dhcpv4, :dhcpv6]
  """
  @spec list_services() :: [atom()]
  defdelegate list_services(), to: YellowDog.ServiceManager

  @doc """
  Formats service status for console display.

  ## Parameters
  - `service` - Service name or `:all` for all services

  ## Returns
  - Formatted string for console display

  ## Examples
      iex> YellowDog.format_status(:all)
      "=== YellowDog Services Status ===\\n\\nDNS: ENABLED | RUNNING\\n  Uptime: 1h 23m\\n..."

      iex> YellowDog.format_status(:mdns)
      "MDNS: ENABLED | RUNNING\\n  Uptime: 45m 12s\\n  Cache: 120 active entries, 30 expired"
  """
  @spec format_status(atom()) :: String.t()
  defdelegate format_status(service), to: YellowDog.ServiceManager
end
