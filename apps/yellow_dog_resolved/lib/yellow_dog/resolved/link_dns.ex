defmodule YellowDog.Resolved.LinkDns do
  @moduledoc """
  Per-link DNS configuration storage.

  Stores DNS server and search domain configuration per network interface,
  as pushed by YellowDog.Netman. Higher-priority links' DNS servers are
  prepended to the global upstream list in the Forwarder.
  """

  use GenServer

  require Logger

  @table :resolved_link_dns

  @type link_config :: %{
          servers: [:inet.ip_address()],
          search: [String.t()],
          priority: non_neg_integer()
        }

  # Client API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Set DNS configuration for a network interface.

  Merges the link's DNS servers into the Forwarder's upstream list,
  ordered by priority (higher priority = earlier in list).
  """
  @spec set_link_dns(String.t(), map()) :: :ok
  def set_link_dns(interface, config) when is_binary(interface) and is_map(config) do
    GenServer.call(__MODULE__, {:set, interface, config})
  end

  @doc """
  Remove DNS configuration for a network interface.
  """
  @spec reset_link_dns(String.t()) :: :ok
  def reset_link_dns(interface) when is_binary(interface) do
    GenServer.call(__MODULE__, {:reset, interface})
  end

  @doc "Get all per-link DNS configurations."
  @spec list_all() :: %{String.t() => link_config()}
  def list_all do
    try do
      :ets.tab2list(@table)
      |> Enum.into(%{}, fn {iface, config} -> {iface, config} end)
    rescue
      ArgumentError -> %{}
    end
  end

  @doc "Get DNS configuration for a specific interface."
  @spec get(String.t()) :: link_config() | nil
  def get(interface) do
    case :ets.lookup(@table, interface) do
      [{_key, config}] -> config
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc """
  Returns merged DNS servers from all active links, ordered by priority
  (highest priority first), followed by global upstreams.
  """
  @spec effective_upstreams() :: [:inet.ip_address()]
  def effective_upstreams do
    link_servers =
      try do
        :ets.tab2list(@table)
        |> Enum.sort_by(fn {_iface, config} -> -(config.priority || 0) end)
        |> Enum.flat_map(fn {_iface, config} -> config.servers || [] end)
      rescue
        ArgumentError -> []
      end

    global_upstreams = YellowDog.Resolved.Config.get(:upstreams) || []

    Enum.uniq(link_servers ++ global_upstreams)
  end

  @doc "Returns merged search domains from all active links, ordered by priority."
  @spec effective_search_domains() :: [String.t()]
  def effective_search_domains do
    try do
      :ets.tab2list(@table)
      |> Enum.sort_by(fn {_iface, config} -> -(config.priority || 0) end)
      |> Enum.flat_map(fn {_iface, config} -> config.search || [] end)
      |> Enum.uniq()
    rescue
      ArgumentError -> []
    end
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    try do: :ets.delete(@table), catch: (_, _ -> :ok)
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:set, interface, config}, _from, state) do
    normalized = normalize_config(config)
    :ets.insert(@table, {interface, normalized})

    Logger.info(
      "[Resolved] Link DNS set for #{interface}: #{length(normalized.servers)} servers, " <>
        "#{length(normalized.search)} search domains, priority=#{normalized.priority}"
    )

    update_forwarder_upstreams()
    {:reply, :ok, state}
  end

  def handle_call({:reset, interface}, _from, state) do
    :ets.delete(@table, interface)
    Logger.info("[Resolved] Link DNS reset for #{interface}")
    update_forwarder_upstreams()
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # Private

  defp normalize_config(config) do
    %{
      servers: Map.get(config, :servers, []) |> Enum.filter(&is_tuple/1),
      search: Map.get(config, :search, []) |> Enum.filter(&is_binary/1),
      priority: Map.get(config, :priority, 0)
    }
  end

  defp update_forwarder_upstreams do
    upstreams = effective_upstreams()

    if Process.whereis(YellowDog.Resolved.Forwarder) do
      GenServer.cast(YellowDog.Resolved.Forwarder, {:update_upstreams, upstreams})
    end
  end
end
