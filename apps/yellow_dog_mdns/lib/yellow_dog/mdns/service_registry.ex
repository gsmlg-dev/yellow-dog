defmodule YellowDog.Mdns.ServiceRegistry do
  @moduledoc """
  Registry for managing locally registered mDNS services.

  Stores service definitions in ETS for fast lookups, manages service lifecycle
  (probing, announcing, registered), and handles persistence to/from files.
  """

  use GenServer
  use YellowDog.Data.Collection

  alias YellowDog.Data.Store
  alias YellowDog.Mdns.{Client, RecordBuilder, ServiceStore}

  defcollection(:mdns_services,
    key_field: :id,
    adapter: YellowDog.Data.Store.Ets
  )

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
    case Store.get(store_state(), service_id) do
      {:ok, service} -> service
      {:error, :not_found} -> nil
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

    {:ok, services} = Store.list(store_state())

    services
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
      qname = normalize_name(question.name)
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

  @doc false
  @spec canonical_service_id(String.t(), String.t()) :: service_id()
  def canonical_service_id(name, type) when is_binary(name) and is_binary(type) do
    "#{name}.#{normalize_service_type(type)}.local"
  end

  @doc false
  @spec control_snapshot() :: {:ok, [service()]} | {:error, :registry_absent}
  def control_snapshot, do: control_call(:control_snapshot)

  @doc false
  @spec control_register_service(service_id(), map()) ::
          {:ok, [service()], [service()]} | {:error, term()}
  def control_register_service(service_id, service_def)
      when is_binary(service_id) and is_map(service_def) do
    control_call({:control_register_service, service_id, service_def})
  end

  def control_register_service(_service_id, _service_def), do: {:error, :invalid_service}

  @doc false
  @spec control_update_service(service_id(), map()) ::
          {:ok, [service()], [service()]} | {:error, term()}
  def control_update_service(service_id, service_def)
      when is_binary(service_id) and is_map(service_def) do
    control_call({:control_update_service, service_id, service_def})
  end

  def control_update_service(_service_id, _service_def), do: {:error, :invalid_service}

  @doc false
  @spec control_delete_service(service_id()) :: {:ok, [service()], [service()]} | {:error, term()}
  def control_delete_service(service_id) when is_binary(service_id),
    do: control_call({:control_delete_service, service_id})

  def control_delete_service(_service_id), do: {:error, :invalid_service_id}

  @doc false
  @spec control_toggle_service(service_id()) :: {:ok, [service()], [service()]} | {:error, term()}
  def control_toggle_service(service_id) when is_binary(service_id),
    do: control_call({:control_toggle_service, service_id})

  def control_toggle_service(_service_id), do: {:error, :invalid_service_id}

  @doc false
  @spec control_commit_snapshot([service()], {atom(), service_id()}) ::
          {:ok, [service()], [service()]} | {:error, term()}
  def control_commit_snapshot(services, {event, service_id})
      when is_list(services) and is_atom(event) and is_binary(service_id) do
    control_call({:control_commit_snapshot, services, {event, service_id}})
  end

  def control_commit_snapshot(_services, _change), do: {:error, :invalid_snapshot}

  @doc """
  Gets registry statistics.
  """
  @spec stats() :: map()
  def stats do
    services = list_services()
    by_state = Enum.frequencies_by(services, & &1.state)
    by_source = Enum.frequencies_by(services, & &1.source)

    %{
      total: length(services),
      enabled: Enum.count(services, & &1.enabled),
      disabled: Enum.count(services, &(not &1.enabled)),
      registered: Map.get(by_state, :registered, 0),
      probing: Map.get(by_state, :probing, 0),
      announcing: Map.get(by_state, :announcing, 0),
      from_file: Map.get(by_source, :file, 0),
      from_api: Map.get(by_source, :api, 0)
    }
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    # Initialize Store.Ets collection
    ets_opts = [:named_table, :set, :public, read_concurrency: true, write_concurrency: true]
    {:ok, store} = Store.init(collection(), ets_opts: ets_opts)
    :persistent_term.put({__MODULE__, :store}, store)

    # Get configuration
    storage_file = Keyword.get(opts, :storage_file, "data/mdns/services.toml")
    auto_save = Keyword.get(opts, :auto_save, true)
    load_on_start = Keyword.get(opts, :load_on_start, true)

    state = %{
      store: store,
      storage_file: storage_file,
      auto_save: auto_save,
      hostname: get_hostname(),
      control_apply_hook: Keyword.get(opts, :control_apply_hook),
      control_save_hook: Keyword.get(opts, :control_save_hook)
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

  @impl true
  def handle_call({:unregister_service, service_id, opts}, _from, state) do
    persist = Keyword.get(opts, :persist, false)

    case get_service(service_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      service ->
        # RFC 6762 §10.1: Send goodbye records (TTL=0) before removing the
        # service so that other mDNS hosts can immediately invalidate their
        # caches rather than waiting for the original TTL to expire.
        Task.start(fn -> send_goodbye_records(service) end)

        {:ok, store} = Store.delete(state.store, service_id)
        state = update_store(state, store)

        if persist and state.auto_save do
          save_services_to_file(state)
        end

        notify_service_change(:unregistered, service_id)
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:update_service, service_id, updates, opts}, _from, state) do
    persist = Keyword.get(opts, :persist, false)

    case get_service(service_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      service ->
        updated_service = Map.merge(service, updates)
        {:ok, store} = Store.put(state.store, service_id, updated_service)
        state = update_store(state, store)

        if persist and state.auto_save do
          save_services_to_file(state)
        end

        notify_service_change(:updated, service_id)
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:toggle_service, service_id}, _from, state) do
    case get_service(service_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      service ->
        updated_service = %{service | enabled: not service.enabled}
        {:ok, store} = Store.put(state.store, service_id, updated_service)
        state = update_store(state, store)

        if state.auto_save do
          save_services_to_file(state)
        end

        notify_service_change(:toggled, service_id)
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call(:load_from_file, _from, state) do
    case ServiceStore.load_services(state.storage_file) do
      {:ok, services} ->
        # Clear existing file-based services and register new ones
        clear_file_services()

        Enum.each(services, fn service_def ->
          register_service_internal(service_def, state, source: :file)
        end)

        {:reply, {:ok, length(services)}, state}

      error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call(:save_to_file, _from, state) do
    result = save_services_to_file(state)
    {:reply, result, state}
  end

  @impl true
  def handle_call(:control_snapshot, _from, state) do
    {:reply, {:ok, snapshot_services(state)}, state}
  end

  @impl true
  def handle_call({:control_register_service, service_id, service_def}, _from, state) do
    prior = snapshot_services(state)

    with {:ok, fixed_def} <- control_service_def(service_id, service_def),
         service <- build_service(fixed_def, state, :api),
         candidate <- replace_service(prior, service) do
      reply_control_commit(state, prior, candidate, {:registered, service_id})
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:control_update_service, service_id, service_def}, _from, state) do
    prior = snapshot_services(state)

    case Enum.find(prior, &(&1.id == service_id)) do
      nil ->
        {:reply, {:error, :not_found}, state}

      service ->
        updated_def = control_update_def(service, service_def)

        with {:ok, fixed_def} <- control_service_def(service_id, updated_def),
             updated_service <- update_control_service(service, fixed_def),
             candidate <- replace_service(prior, updated_service) do
          reply_control_commit(state, prior, candidate, {:updated, service_id})
        else
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_call({:control_delete_service, service_id}, _from, state) do
    prior = snapshot_services(state)

    if Enum.any?(prior, &(&1.id == service_id)) do
      candidate = Enum.reject(prior, &(&1.id == service_id))
      reply_control_commit(state, prior, candidate, {:unregistered, service_id})
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:control_toggle_service, service_id}, _from, state) do
    prior = snapshot_services(state)

    case Enum.find(prior, &(&1.id == service_id)) do
      nil ->
        {:reply, {:error, :not_found}, state}

      service ->
        candidate = replace_service(prior, %{service | enabled: not service.enabled})
        reply_control_commit(state, prior, candidate, {:toggled, service_id})
    end
  end

  @impl true
  def handle_call({:control_commit_snapshot, candidate, change}, _from, state) do
    reply_control_commit(state, snapshot_services(state), candidate, change)
  end

  @impl true
  def handle_cast({:reload_from_file, services}, state) do
    # Clear old file-based services and register new ones
    clear_file_services()

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

  defp reply_control_commit(state, prior, candidate, {event, service_id} = change) do
    case control_commit(state, prior, candidate, change) do
      {:ok, resulting} ->
        notify_service_change(event, service_id)
        {:reply, {:ok, prior, resulting}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp control_commit(state, prior, candidate, change) do
    with :ok <- validate_control_change(change),
         :ok <- validate_control_snapshot(candidate),
         :ok <- persist_control_snapshot(state, candidate),
         :ok <- apply_control_snapshot(state, candidate) do
      {:ok, stable_snapshot(candidate)}
    else
      {:error, :invalid_change} ->
        {:error, :invalid_snapshot}

      {:error, :invalid_snapshot} ->
        {:error, :invalid_snapshot}

      {:error, :persistence_failed} ->
        {:error, :persistence_failed}

      {:error, :apply_failed} ->
        case rollback_control_snapshot(state, prior) do
          :ok -> {:error, :apply_failed}
          {:error, :rollback_failed} -> {:error, :rollback_failed}
        end
    end
  end

  defp rollback_control_snapshot(state, prior) do
    file_result = persist_control_snapshot(state, prior)
    registry_result = apply_control_snapshot(state, prior)

    if file_result == :ok and registry_result == :ok do
      :ok
    else
      {:error, :rollback_failed}
    end
  end

  defp validate_control_change({event, service_id})
       when event in [:registered, :updated, :unregistered, :toggled] and is_binary(service_id),
       do: :ok

  defp validate_control_change(_change), do: {:error, :invalid_change}

  defp control_service_def(service_id, service_def) do
    fixed_def = %{
      name: Map.get(service_def, :name),
      type: Map.get(service_def, :type),
      port: Map.get(service_def, :port),
      txt: Map.get(service_def, :txt, %{})
    }

    with :ok <- ServiceStore.validate_service(fixed_def),
         true <- service_id == canonical_service_id(fixed_def.name, fixed_def.type) do
      {:ok, fixed_def}
    else
      false -> {:error, :invalid_service_id}
      {:error, _reason} -> {:error, :invalid_service}
    end
  end

  defp control_update_def(service, updates) do
    %{
      name: Map.get(updates, :name, service.name),
      type: Map.get(updates, :type, service.type),
      port: Map.get(updates, :port, service.port),
      txt: Map.get(updates, :txt, service.txt_records)
    }
  end

  defp update_control_service(service, fixed_def) do
    %{
      service
      | name: fixed_def.name,
        type: normalize_service_type(fixed_def.type),
        fqdn: canonical_service_id(fixed_def.name, fixed_def.type),
        port: fixed_def.port,
        txt_records: fixed_def.txt
    }
  end

  defp replace_service(services, service) do
    services
    |> Enum.reject(&(&1.id == service.id))
    |> List.insert_at(-1, service)
    |> stable_snapshot()
  end

  defp validate_control_snapshot(services) when is_list(services) do
    case Enum.reduce_while(services, MapSet.new(), fn service, ids ->
           with :ok <- validate_control_service(service),
                false <- MapSet.member?(ids, service.id) do
             {:cont, MapSet.put(ids, service.id)}
           else
             _ -> {:halt, :invalid_snapshot}
           end
         end) do
      :invalid_snapshot -> {:error, :invalid_snapshot}
      _ids -> :ok
    end
  end

  defp validate_control_snapshot(_services), do: {:error, :invalid_snapshot}

  defp validate_control_service(service) when is_map(service) do
    required_fields = [
      :id,
      :name,
      :type,
      :domain,
      :fqdn,
      :host,
      :port,
      :txt_records,
      :addresses,
      :priority,
      :weight,
      :ttl,
      :state,
      :source,
      :enabled,
      :registered_at,
      :last_announced
    ]

    service_def = %{
      name: Map.get(service, :name),
      type: Map.get(service, :type),
      port: Map.get(service, :port),
      txt: Map.get(service, :txt_records)
    }

    with true <- Enum.all?(required_fields, &Map.has_key?(service, &1)),
         :ok <- ServiceStore.validate_service(service_def),
         true <- service.id == canonical_service_id(service.name, service.type),
         true <- service.fqdn == service.id,
         true <- is_binary(service.host),
         true <- is_list(service.addresses),
         true <- is_boolean(service.enabled) do
      :ok
    else
      _ -> {:error, :invalid_snapshot}
    end
  end

  defp validate_control_service(_service), do: {:error, :invalid_snapshot}

  defp persist_control_snapshot(state, services) do
    service_defs = Enum.map(services, &service_to_def/1)

    result =
      case state.control_save_hook do
        hook when is_function(hook, 2) ->
          safe_control_phase(fn -> hook.(state.storage_file, service_defs) end)

        _ ->
          safe_control_phase(fn ->
            ServiceStore.save_services(state.storage_file, service_defs)
          end)
      end

    case result do
      :ok -> :ok
      :error -> {:error, :persistence_failed}
    end
  end

  defp apply_control_snapshot(state, services) do
    with :ok <- run_control_apply_hook(state.control_apply_hook, services),
         :ok <- replace_snapshot(state.store, services) do
      :ok
    else
      _ -> {:error, :apply_failed}
    end
  end

  defp run_control_apply_hook(hook, services) when is_function(hook, 1),
    do: safe_control_phase(fn -> hook.(stable_snapshot(services)) end)

  defp run_control_apply_hook(_hook, _services), do: :ok

  defp replace_snapshot(store, services) do
    safe_control_phase(fn ->
      :ets.delete_all_objects(store.table)
      true = :ets.insert(store.table, Enum.map(services, &{&1.id, &1}))
      :ok
    end)
  end

  defp safe_control_phase(fun) do
    case fun.() do
      :ok -> :ok
      _ -> :error
    end
  rescue
    _error -> :error
  catch
    _kind, _reason -> :error
  end

  defp snapshot_services(state) do
    {:ok, services} = Store.list(state.store)
    stable_snapshot(services)
  end

  defp stable_snapshot(services), do: Enum.sort_by(services, & &1.id)

  defp control_call(message) do
    GenServer.call(__MODULE__, message)
  catch
    :exit, _reason -> {:error, :registry_absent}
  end

  defp send_goodbye_records(service) do
    goodbye_records = RecordBuilder.build_goodbye_records(service)
    base = DNS.Message.new()

    message = %{
      base
      | header: %{
          base.header
          | id: 0,
            qr: 1,
            aa: 1,
            rd: 0,
            ra: 0,
            qdcount: 0,
            ancount: length(goodbye_records)
        },
        anlist: goodbye_records
    }

    Client.announce(message)
  end

  defp store_state do
    :persistent_term.get({__MODULE__, :store})
  end

  defp update_store(state, store) do
    :persistent_term.put({__MODULE__, :store}, store)
    %{state | store: store}
  end

  defp clear_file_services do
    for service <- list_services(source: :file) do
      Store.delete(store_state(), service.id)
    end

    :ok
  end

  defp register_service_internal(service_def, state, opts) do
    source = Keyword.get(opts, :source, :api)

    with :ok <- ServiceStore.validate_service(service_def) do
      service = build_service(service_def, state, source)
      {:ok, store} = Store.put(store_state(), service.id, service)
      :persistent_term.put({__MODULE__, :store}, store)

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

  defp normalize_service_type(type) when is_binary(type) do
    # Ensure service type has proper format: _service._proto
    cond do
      String.contains?(type, "._") -> type
      String.starts_with?(type, "_") -> type <> "._tcp"
      true -> "_" <> type <> "._tcp"
    end
  end

  defp parse_addresses(addresses) when is_list(addresses) do
    for addr <- addresses, ip = parse_address(addr), ip != nil, do: ip
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
    service_fqdn = normalize_name(service.fqdn)
    service_type = normalize_name("#{service.type}.#{service.domain}")
    service_host = normalize_name(service.host)
    # Normalize qtype to string so both atom (:PTR) and ResourceRecordType struct compare cleanly
    qtype_str = to_string(qtype)

    cond do
      # Direct service name query
      qname == service_fqdn and qtype_str in ["ANY", "SRV", "TXT"] ->
        true

      # Service type enumeration (PTR query)
      qname == service_type and qtype_str == "PTR" ->
        true

      # Host address query
      qname == service_host and qtype_str in ["A", "AAAA", "ANY"] ->
        true

      true ->
        false
    end
  end

  defp normalize_name(name), do: YellowDog.Mdns.normalize_name(name)

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
      txt: if(map_size(service.txt_records) > 0, do: service.txt_records),
      addresses: Enum.map(service.addresses, &format_ip/1),
      enabled: service.enabled
    }
  end

  defp format_ip(ip) when is_tuple(ip), do: ip |> :inet.ntoa() |> to_string()

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
