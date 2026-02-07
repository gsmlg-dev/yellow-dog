defmodule YellowDog.Mdns.ServiceRegistry do
  @moduledoc """
  Registry for managing locally registered mDNS services.

  Stores service definitions in ETS for fast lookups, manages service lifecycle
  (probing, announcing, registered), and handles persistence to/from files.
  """

  use GenServer

  alias YellowDog.Mdns.ServiceStore

  @table_name :mdns_service_registry
  @ets_options [:named_table, :public, :set, read_concurrency: true, write_concurrency: true]

  @type service_id :: String.t()
  @type service_state :: :probing | :announcing | :registered | :disabled

  @type service :: %{
          id: service_id(),
          name: String.t(),
          type: String.t(),
          domain: String.t(),
          fqdn: String.t(),
          host: String.t(),
          port: pos_integer(),
          txt_records: map(),
          addresses: [tuple()],
          priority: non_neg_integer(),
          weight: non_neg_integer(),
          ttl: pos_integer(),
          state: service_state(),
          source: :file | :api,
          enabled: boolean(),
          registered_at: integer(),
          last_announced: integer() | nil
        }

  # Default TTLs per RFC 6762
  @default_service_ttl 4500
  # 75 minutes

  # Client API

  @doc """
  Starts the ServiceRegistry GenServer.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Registers a new service.

  ## Parameters
  - `service_def` - Service definition map
  - `opts` - Options
    - `:persist` - Save to file (default: false)
    - `:source` - Source of registration (:file or :api, default: :api)

  ## Returns
  - `{:ok, service_id}` on success
  - `{:error, reason}` on failure

  ## Examples
      iex> YellowDog.Mdns.ServiceRegistry.register_service(%{
      ...>   name: "Web Server",
      ...>   type: "_http._tcp",
      ...>   port: 8080,
      ...>   txt: %{"path" => "/api"}
      ...> })
      {:ok, "Web Server._http._tcp.local"}
  """
  @spec register_service(map(), keyword()) :: {:ok, service_id()} | {:error, term()}
  def register_service(service_def, opts \\ []) do
    GenServer.call(__MODULE__, {:register_service, service_def, opts})
  end

  @doc """
  Unregisters a service.

  ## Parameters
  - `service_id` - Service identifier
  - `opts` - Options
    - `:persist` - Update file (default: false)
  """
  @spec unregister_service(service_id(), keyword()) :: :ok | {:error, term()}
  def unregister_service(service_id, opts \\ []) do
    GenServer.call(__MODULE__, {:unregister_service, service_id, opts})
  end

  @doc """
  Updates a service.

  ## Parameters
  - `service_id` - Service identifier
  - `updates` - Map of fields to update
  - `opts` - Options
    - `:persist` - Save to file (default: false)
  """
  @spec update_service(service_id(), map(), keyword()) :: :ok | {:error, term()}
  def update_service(service_id, updates, opts \\ []) do
    GenServer.call(__MODULE__, {:update_service, service_id, updates, opts})
  end

  @doc """
  Enables or disables a service.
  """
  @spec toggle_service(service_id()) :: :ok | {:error, term()}
  def toggle_service(service_id) do
    GenServer.call(__MODULE__, {:toggle_service, service_id})
  end

  @doc """
  Gets a service by ID.
  """
  @spec get_service(service_id()) :: service() | nil
  def get_service(service_id) do
    case :ets.lookup(@table_name, service_id) do
      [{^service_id, service}] -> service
      [] -> nil
    end
  end

  @doc """
  Lists all registered services.

  ## Options
  - `:filter` - Filter services (:all, :enabled, :disabled, :registered)
  - `:source` - Filter by source (:file, :api, :all)
  """
  @spec list_services(keyword()) :: [service()]
  def list_services(opts \\ []) do
    filter = Keyword.get(opts, :filter, :all)
    source_filter = Keyword.get(opts, :source, :all)

    @table_name
    |> :ets.tab2list()
    |> Enum.map(&elem(&1, 1))
    |> apply_filters(filter, source_filter)
    |> Enum.sort_by(& &1.name)
  end

  @doc """
  Gets DNS records for a query.

  Used by the Responder to match incoming queries against registered services.

  ## Parameters
  - `questions` - List of DNS questions from query
  """
  @spec get_records_for_query([DNS.Question.t()]) :: [service()]
  def get_records_for_query(questions) do
    Enum.flat_map(questions, fn question ->
      qname = to_string(question.name) |> String.downcase() |> String.trim_trailing(".")
      qtype = question.type

      # Find matching services
      list_services(filter: :registered)
      |> Enum.filter(fn service ->
        matches_query?(service, qname, qtype)
      end)
    end)
    |> Enum.uniq_by(& &1.id)
  end

  @doc """
  Reloads services from file.

  Called by FileWatcher when the services file changes.
  """
  @spec reload_from_file([map()]) :: :ok
  def reload_from_file(services) do
    GenServer.cast(__MODULE__, {:reload_from_file, services})
  end

  @doc """
  Loads services from the configured file.
  """
  @spec load_from_file() :: {:ok, integer()} | {:error, term()}
  def load_from_file do
    GenServer.call(__MODULE__, :load_from_file)
  end

  @doc """
  Saves current services to file.
  """
  @spec save_to_file() :: :ok | {:error, term()}
  def save_to_file do
    GenServer.call(__MODULE__, :save_to_file)
  end

  @doc """
  Gets registry statistics.
  """
  @spec stats() :: map()
  def stats do
    services = list_services()

    %{
      total: length(services),
      enabled: Enum.count(services, & &1.enabled),
      disabled: Enum.count(services, &(not &1.enabled)),
      registered: Enum.count(services, &(&1.state == :registered)),
      probing: Enum.count(services, &(&1.state == :probing)),
      announcing: Enum.count(services, &(&1.state == :announcing)),
      from_file: Enum.count(services, &(&1.source == :file)),
      from_api: Enum.count(services, &(&1.source == :api))
    }
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    # Initialize ETS table
    init_table()

    # Get configuration
    storage_file = Keyword.get(opts, :storage_file, "data/mdns/services.toml")
    auto_save = Keyword.get(opts, :auto_save, true)
    load_on_start = Keyword.get(opts, :load_on_start, true)

    state = %{
      storage_file: storage_file,
      auto_save: auto_save,
      hostname: get_hostname()
    }

    # Load services from file if configured
    if load_on_start do
      case ServiceStore.load_services(storage_file) do
        {:ok, services} ->
          Enum.each(services, fn service_def ->
            register_service_internal(service_def, state, source: :file)
          end)

          :telemetry.execute(
            [:yellow_dog, :mdns, :service_registry, :loaded_from_file],
            %{service_count: length(services)},
            %{file: storage_file}
          )

        {:error, reason} ->
          :telemetry.execute(
            [:yellow_dog, :mdns, :service_registry, :load_failed],
            %{count: 1},
            %{reason: inspect(reason), file: storage_file}
          )
      end
    end

    {:ok, state}
  end

  @impl true
  def handle_call({:register_service, service_def, opts}, _from, state) do
    source = Keyword.get(opts, :source, :api)
    persist = Keyword.get(opts, :persist, false)

    case register_service_internal(service_def, state, source: source) do
      {:ok, service_id} ->
        if persist and state.auto_save do
          save_services_to_file(state)
        end

        notify_service_change(:registered, service_id)
        {:reply, {:ok, service_id}, state}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:unregister_service, service_id, opts}, _from, state) do
    persist = Keyword.get(opts, :persist, false)

    case :ets.lookup(@table_name, service_id) do
      [{^service_id, _service}] ->
        :ets.delete(@table_name, service_id)

        if persist and state.auto_save do
          save_services_to_file(state)
        end

        notify_service_change(:unregistered, service_id)
        {:reply, :ok, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:update_service, service_id, updates, opts}, _from, state) do
    persist = Keyword.get(opts, :persist, false)

    case :ets.lookup(@table_name, service_id) do
      [{^service_id, service}] ->
        updated_service = Map.merge(service, updates)
        :ets.insert(@table_name, {service_id, updated_service})

        if persist and state.auto_save do
          save_services_to_file(state)
        end

        notify_service_change(:updated, service_id)
        {:reply, :ok, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:toggle_service, service_id}, _from, state) do
    case :ets.lookup(@table_name, service_id) do
      [{^service_id, service}] ->
        updated_service = %{service | enabled: not service.enabled}
        :ets.insert(@table_name, {service_id, updated_service})

        if state.auto_save do
          save_services_to_file(state)
        end

        notify_service_change(:toggled, service_id)
        {:reply, :ok, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:load_from_file, _from, state) do
    case ServiceStore.load_services(state.storage_file) do
      {:ok, services} ->
        # Clear existing file-based services
        list_services(source: :file)
        |> Enum.each(fn service ->
          :ets.delete(@table_name, service.id)
        end)

        # Register new services
        Enum.each(services, fn service_def ->
          register_service_internal(service_def, state, source: :file)
        end)

        {:reply, {:ok, length(services)}, state}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call(:save_to_file, _from, state) do
    result = save_services_to_file(state)
    {:reply, result, state}
  end

  @impl true
  def handle_cast({:reload_from_file, services}, state) do
    # Remove old file-based services
    list_services(source: :file)
    |> Enum.each(fn service ->
      :ets.delete(@table_name, service.id)
    end)

    # Register new services from file
    Enum.each(services, fn service_def ->
      register_service_internal(service_def, state, source: :file)
    end)

    :telemetry.execute(
      [:yellow_dog, :mdns, :service_registry, :reloaded_from_file],
      %{service_count: length(services)},
      %{}
    )

    {:noreply, state}
  end

  # Private functions

  defp init_table do
    if :ets.whereis(@table_name) == :undefined do
      :ets.new(@table_name, @ets_options)
    end

    :ok
  end

  defp register_service_internal(service_def, state, opts) do
    source = Keyword.get(opts, :source, :api)

    with :ok <- ServiceStore.validate_service(service_def) do
      service = build_service(service_def, state, source)
      :ets.insert(@table_name, {service.id, service})

      :telemetry.execute(
        [:yellow_dog, :mdns, :service_registered],
        %{},
        %{service_id: service.id, source: source}
      )

      {:ok, service.id}
    end
  end

  defp build_service(service_def, state, source) do
    type_with_proto = normalize_service_type(service_def.type)
    domain = "local"
    name = service_def.name
    host = service_def[:host] || state.hostname

    # Build FQDN: name.type.domain
    fqdn = "#{name}.#{type_with_proto}.#{domain}"

    %{
      id: fqdn,
      name: name,
      type: type_with_proto,
      domain: domain,
      fqdn: fqdn,
      host: "#{host}.#{domain}",
      port: service_def.port,
      txt_records: service_def[:txt] || %{},
      addresses: parse_addresses(service_def[:addresses] || []),
      priority: 0,
      weight: 0,
      ttl: @default_service_ttl,
      state: if(service_def[:enabled] != false, do: :registered, else: :disabled),
      source: source,
      enabled: service_def[:enabled] != false,
      registered_at: System.system_time(:second),
      last_announced: nil
    }
  end

  defp normalize_service_type(type) do
    # Ensure service type has proper format: _service._proto
    cond do
      String.contains?(type, "._") -> type
      String.starts_with?(type, "_") -> type <> "._tcp"
      true -> "_" <> type <> "._tcp"
    end
  end

  defp parse_addresses(addresses) when is_list(addresses) do
    Enum.map(addresses, &parse_address/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_addresses(_), do: []

  defp parse_address(addr) when is_binary(addr) do
    case :inet.parse_address(String.to_charlist(addr)) do
      {:ok, ip_tuple} -> ip_tuple
      _ -> nil
    end
  end

  defp parse_address(addr) when is_tuple(addr), do: addr
  defp parse_address(_), do: nil

  defp matches_query?(service, qname, qtype) do
    # Match service FQDN or type enumeration
    service_fqdn = String.downcase(service.fqdn) |> String.trim_trailing(".")

    service_type =
      String.downcase("#{service.type}.#{service.domain}") |> String.trim_trailing(".")

    service_host = String.downcase(service.host) |> String.trim_trailing(".")

    cond do
      # Direct service name query
      qname == service_fqdn and qtype in [:ANY, :SRV, :TXT] ->
        true

      # Service type enumeration (PTR query)
      qname == service_type and qtype == :PTR ->
        true

      # Host address query
      qname == service_host and qtype in [:A, :AAAA, :ANY] ->
        true

      true ->
        false
    end
  end

  defp apply_filters(services, filter, source_filter) do
    services
    |> apply_state_filter(filter)
    |> apply_source_filter(source_filter)
  end

  defp apply_state_filter(services, :all), do: services
  defp apply_state_filter(services, :enabled), do: Enum.filter(services, & &1.enabled)
  defp apply_state_filter(services, :disabled), do: Enum.filter(services, &(not &1.enabled))

  defp apply_state_filter(services, :registered),
    do: Enum.filter(services, &(&1.state == :registered))

  defp apply_source_filter(services, :all), do: services
  defp apply_source_filter(services, source), do: Enum.filter(services, &(&1.source == source))

  defp save_services_to_file(state) do
    services =
      list_services()
      |> Enum.map(&service_to_def/1)

    ServiceStore.save_services(state.storage_file, services)
  end

  defp service_to_def(service) do
    %{
      name: service.name,
      type: service.type,
      port: service.port,
      host: String.replace_suffix(service.host, ".#{service.domain}", ""),
      txt: if(map_size(service.txt_records) > 0, do: service.txt_records, else: nil),
      addresses: Enum.map(service.addresses, &format_ip/1),
      enabled: service.enabled
    }
  end

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"

  defp format_ip({a, b, c, d, e, f, g, h}) do
    Enum.map_join([a, b, c, d, e, f, g, h], ":", &Integer.to_string(&1, 16))
  end

  defp get_hostname do
    case :inet.gethostname() do
      {:ok, hostname} -> to_string(hostname)
      _ -> "localhost"
    end
  end

  defp notify_service_change(event, service_id) do
    # Notify web console if available
    # Map internal event names to expected LiveView event names
    pubsub_event =
      case event do
        :registered -> :service_registered
        :unregistered -> :service_unregistered
        :updated -> :service_updated
        :toggled -> :service_toggled
        other -> other
      end

    case Process.whereis(YellowDog.Console.PubSub) do
      nil ->
        :ok

      _pid ->
        try do
          apply(Phoenix.PubSub, :broadcast, [
            YellowDog.Console.PubSub,
            "mdns:services",
            {pubsub_event, service_id}
          ])
        rescue
          _e in [ArgumentError, UndefinedFunctionError] -> :ok
        end
    end
  end
end
