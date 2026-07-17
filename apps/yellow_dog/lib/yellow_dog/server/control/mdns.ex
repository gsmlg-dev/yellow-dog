defmodule YellowDog.Server.Control.Mdns do
  @moduledoc false

  alias YellowDog.Server.Control.Revision
  alias YellowDog.Sync.Bounds
  alias YellowDog.Sync.Error
  alias YellowDog.Sync.Operation
  alias YellowDog.Sync.ServerOperation

  @validation_observed_at "1970-01-01T00:00:00Z"
  @validation_revision String.duplicate("0", 64)
  @service_mutations [
    "server.mdns.services.register",
    "server.mdns.services.update",
    "server.mdns.services.delete",
    "server.mdns.services.toggle"
  ]
  @mutation_operations @service_mutations ++ ["server.mdns.cache.clear"]
  @production_dependencies %{
    registry: Module.concat(["YellowDog", "Mdns", "ServiceRegistry"]),
    cache: Module.concat(["YellowDog", "Mdns", "MessageCache"]),
    monitor: Module.concat(["YellowDog", "Mdns", "NetworkMonitor"]),
    clock: DateTime
  }
  @test_environment Mix.env() == :test

  @spec dispatch(String.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def dispatch("server.mdns.services.list", payload), do: list_services(payload)
  def dispatch("server.mdns.discovery.list", payload), do: list_discovery(payload)
  def dispatch("server.mdns.monitor.list", payload), do: unsupported_monitor(payload)
  def dispatch("server.mdns.cache.get", payload), do: get_cache(payload)
  def dispatch("server.mdns.services.register", payload), do: mutate_service(:register, payload)
  def dispatch("server.mdns.services.update", payload), do: mutate_service(:update, payload)
  def dispatch("server.mdns.services.delete", payload), do: mutate_service(:delete, payload)
  def dispatch("server.mdns.services.toggle", payload), do: mutate_service(:toggle, payload)
  def dispatch("server.mdns.cache.clear", payload), do: clear_cache(payload)
  def dispatch(_operation, _payload), do: unsupported_error()

  @spec current(String.t(), map()) :: {:ok, map() | :missing} | {:error, Error.t()}
  def current("server.mdns.services.register", payload) do
    with {:ok, payload} <- validate_payload("server.mdns.services.register", payload),
         {:ok, _service_def} <- service_definition(payload),
         {:ok, services} <- registry_resources() do
      case find_service(services, payload["service_id"]) do
        nil -> {:ok, :missing}
        service -> {:ok, revision_source(service)}
      end
    end
  end

  def current(operation, payload) when operation in @service_mutations do
    with {:ok, payload} <- validate_payload(operation, payload),
         :ok <- validate_service_mutation_payload(operation, payload),
         {:ok, services} <- registry_resources(),
         service when not is_nil(service) <- find_service(services, payload["service_id"]) do
      {:ok, revision_source(service)}
    else
      nil -> not_found_error()
      {:error, %Error{}} = error -> error
    end
  end

  def current("server.mdns.cache.clear", payload) do
    with {:ok, _payload} <- validate_payload("server.mdns.cache.clear", payload),
         {:ok, entries} <- cache_entries() do
      {:ok, %{"entries" => entries}}
    end
  end

  def current(operation, _payload) when operation in @mutation_operations, do: invalid_error()
  def current(_operation, _payload), do: unsupported_error()

  defp list_services(payload) do
    with {:ok, payload} <- validate_payload("server.mdns.services.list", payload),
         {:ok, services} <- registry_resources() do
      list_result("server.mdns.services.list", services, payload, & &1.resource["service_id"])
    end
  end

  defp list_discovery(payload) do
    with {:ok, payload} <- validate_payload("server.mdns.discovery.list", payload),
         {:ok, discovered} <- discovered_services(),
         {:ok, items} <- project_discovered_services(discovered) do
      list_result("server.mdns.discovery.list", items, payload, &discovery_key/1)
    end
  end

  defp unsupported_monitor(payload) do
    with {:ok, _payload} <- validate_payload("server.mdns.monitor.list", payload) do
      unsupported_error()
    end
  end

  defp get_cache(payload) do
    with {:ok, _payload} <- validate_payload("server.mdns.cache.get", payload),
         {:ok, entries} <- cache_entries(),
         {:ok, result} <- validate_result("server.mdns.cache.get", %{"entries" => entries}) do
      {:ok, result}
    end
  end

  defp mutate_service(action, payload) do
    operation = service_operation(action)

    with {:ok, payload} <- validate_payload(operation, payload),
         :ok <- validate_service_mutation_payload(operation, payload),
         {:ok, resulting} <- registry_mutation(action, payload) do
      service_mutation_result(action, payload["service_id"], resulting)
    end
  end

  defp clear_cache(payload) do
    with {:ok, _payload} <- validate_payload("server.mdns.cache.clear", payload),
         {:ok, cleared_entries} <- cache_clear_result(),
         {:ok, result} <-
           validate_result("server.mdns.cache.clear", %{"cleared_entries" => cleared_entries}) do
      {:ok, result}
    end
  end

  defp validate_service_mutation_payload(operation, payload)
       when operation in ["server.mdns.services.register", "server.mdns.services.update"] do
    with {:ok, _service_def} <- service_definition(payload) do
      :ok
    end
  end

  defp validate_service_mutation_payload(_operation, _payload), do: :ok

  defp service_definition(payload) do
    with {:ok, txt} <- txt_map(payload["txt"]),
         true <-
           payload["service_id"] == canonical_service_id(payload["name"], payload["service_type"]) do
      {:ok,
       %{
         name: payload["name"],
         type: payload["service_type"],
         port: payload["service_port"],
         txt: txt
       }}
    else
      false -> invalid_error()
      {:error, %Error{}} = error -> error
    end
  end

  defp txt_map(entries) when is_list(entries) do
    Enum.reduce_while(entries, {:ok, %{}}, fn
      %{"key" => key, "value" => value}, {:ok, txt} ->
        if Map.has_key?(txt, key) do
          {:halt, invalid_error()}
        else
          {:cont, {:ok, Map.put(txt, key, value)}}
        end

      _entry, _txt ->
        {:halt, invalid_error()}
    end)
  end

  defp txt_map(_entries), do: invalid_error()

  defp canonical_service_id(name, type) do
    normalized_type =
      cond do
        String.contains?(type, "._") -> type
        String.starts_with?(type, "_") -> type <> "._tcp"
        true -> "_" <> type <> "._tcp"
      end

    name <> "." <> normalized_type <> ".local"
  end

  defp registry_resources do
    with {:ok, snapshot} <- registry_snapshot(),
         {:ok, services} <- project_services(snapshot) do
      {:ok, services}
    end
  end

  defp registry_snapshot do
    case dependency_call(:registry, :control_snapshot, []) do
      {:ok, {:ok, snapshot}} when is_list(snapshot) -> {:ok, snapshot}
      {:ok, {:ok, _snapshot}} -> invalid_error()
      {:ok, {:error, reason}} -> owner_error(reason)
      {:ok, _result} -> apply_failed_error()
      {:error, %Error{}} = error -> error
    end
  end

  defp project_services(services) when is_list(services) do
    Enum.reduce_while(services, {:ok, []}, fn service, {:ok, projected} ->
      case project_service(service) do
        {:ok, service} -> {:cont, {:ok, [service | projected]}}
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, projected} -> {:ok, Enum.reverse(projected)}
      {:error, %Error{}} = error -> error
    end
  end

  defp project_services(_services), do: invalid_error()

  defp project_service(service) when is_map(service) do
    resource = %{
      "service_id" => field(service, :id),
      "name" => field(service, :name),
      "service_type" => field(service, :type),
      "service_port" => field(service, :port),
      "txt" => service_txt(field(service, :txt_records))
    }

    with true <- is_boolean(field(service, :enabled)),
         {:ok, resource} <- validate_service_resource(resource) do
      {:ok, %{resource: resource, enabled: field(service, :enabled)}}
    else
      false -> invalid_error()
      {:error, %Error{}} = error -> error
    end
  end

  defp project_service(_service), do: invalid_error()

  defp service_txt(txt) when is_map(txt) do
    txt
    |> Enum.map(fn {key, value} -> %{"key" => key, "value" => value} end)
    |> Enum.sort_by(& &1["key"])
  end

  defp service_txt(_txt), do: nil

  defp validate_service_resource(resource) do
    validation = %{
      "items" => [resource],
      "revision" => @validation_revision,
      "observed_at" => @validation_observed_at
    }

    case validate_result("server.mdns.services.list", validation) do
      {:ok, _validation} -> {:ok, resource}
      {:error, %Error{}} = error -> error
    end
  end

  defp discovered_services do
    case dependency_call(:monitor, :list_discovered_services, []) do
      {:ok, services} when is_list(services) -> {:ok, services}
      {:ok, {:error, reason}} -> owner_error(reason)
      {:ok, _services} -> apply_failed_error()
      {:error, %Error{}} = error -> error
    end
  end

  defp project_discovered_services(services) do
    items =
      Enum.flat_map(services, fn service ->
        for address <- List.wrap(field(service, :addresses)),
            {:ok, address} <- [canonical_ip(address)],
            item = %{
              "name" => field(service, :service_id),
              "service_type" => field(service, :type),
              "address" => address
            },
            valid_discovery_item?(item),
            do: item
      end)
      |> Enum.uniq_by(&{&1["name"], &1["address"]})

    {:ok, items}
  end

  defp canonical_ip(address) when is_binary(address) do
    case :inet.parse_address(String.to_charlist(address)) do
      {:ok, parsed} -> canonical_ip(parsed)
      _ -> :error
    end
  end

  defp canonical_ip(address) when is_tuple(address) and tuple_size(address) in [4, 8] do
    try do
      value = address |> :inet.ntoa() |> List.to_string()

      case :inet.parse_address(String.to_charlist(value)) do
        {:ok, ^address} -> {:ok, value}
        _ -> :error
      end
    rescue
      _exception -> :error
    catch
      _kind, _reason -> :error
    end
  end

  defp canonical_ip(_address), do: :error

  defp valid_discovery_item?(item) do
    validation = %{
      "items" => [item],
      "revision" => @validation_revision,
      "observed_at" => @validation_observed_at
    }

    match?({:ok, _result}, validate_result("server.mdns.discovery.list", validation))
  end

  defp cache_entries do
    with {:ok, entries} <- cache_snapshot(),
         entries <- sort_and_bound(entries, &cache_key/1),
         {:ok, _result} <- validate_result("server.mdns.cache.get", %{"entries" => entries}) do
      {:ok, entries}
    end
  end

  defp cache_snapshot do
    case dependency_call(:cache, :control_snapshot, []) do
      {:ok, {:ok, entries}} when is_list(entries) -> {:ok, entries}
      {:ok, {:ok, _entries}} -> invalid_error()
      {:ok, {:error, reason}} -> owner_error(reason)
      {:ok, _result} -> apply_failed_error()
      {:error, %Error{}} = error -> error
    end
  end

  defp cache_clear_result do
    case dependency_call(:cache, :control_clear, []) do
      {:ok, {:ok, count}} when is_integer(count) and count >= 0 -> {:ok, count}
      {:ok, {:ok, _count}} -> invalid_error()
      {:ok, {:error, reason}} -> owner_error(reason)
      {:ok, _result} -> apply_failed_error()
      {:error, %Error{}} = error -> error
    end
  end

  defp registry_mutation(action, payload) do
    with {:ok, result} <- registry_call(action, payload),
         {:ok, _prior} <- project_services(elem(result, 0)),
         {:ok, resulting} <- project_services(elem(result, 1)) do
      {:ok, resulting}
    end
  end

  defp registry_call(:register, payload) do
    with {:ok, service_def} <- service_definition(payload) do
      mutation_owner_result(:control_register_service, [payload["service_id"], service_def])
    end
  end

  defp registry_call(:update, payload) do
    with {:ok, service_def} <- service_definition(payload) do
      mutation_owner_result(:control_update_service, [payload["service_id"], service_def])
    end
  end

  defp registry_call(:delete, payload),
    do: mutation_owner_result(:control_delete_service, [payload["service_id"]])

  defp registry_call(:toggle, payload),
    do:
      mutation_owner_result(:control_toggle_service, [payload["service_id"], payload["enabled"]])

  defp mutation_owner_result(function, arguments) do
    case dependency_call(:registry, function, arguments) do
      {:ok, {:ok, prior, resulting}} when is_list(prior) and is_list(resulting) ->
        {:ok, {prior, resulting}}

      {:ok, {:ok, _prior, _resulting}} ->
        invalid_error()

      {:ok, {:error, reason}} ->
        owner_error(reason)

      {:ok, _result} ->
        apply_failed_error()

      {:error, %Error{}} = error ->
        error
    end
  end

  defp service_mutation_result(action, service_id, services)
       when action in [:register, :update, :toggle] do
    with service when not is_nil(service) <- find_service(services, service_id),
         source <- revision_source(service),
         {:ok, revision} <- Revision.calculate(source),
         {:ok, result} <-
           validate_result(service_operation(action), %{
             "resource_type" => "mdns_service",
             "resource_id" => service_id,
             "revision" => revision,
             "resource" => service.resource
           }) do
      {:ok, result}
    else
      nil -> invalid_error()
      {:error, %Error{}} = error -> error
    end
  end

  defp service_mutation_result(:delete, service_id, services) do
    if is_nil(find_service(services, service_id)) do
      ref = %{"service_id" => service_id}

      with {:ok, revision} <- Revision.calculate(ref),
           {:ok, result} <-
             validate_result("server.mdns.services.delete", %{
               "resource_type" => "mdns_service",
               "resource_id" => service_id,
               "revision" => revision,
               "resource_ref" => ref
             }) do
        {:ok, result}
      end
    else
      apply_failed_error()
    end
  end

  defp find_service(services, service_id) do
    Enum.find(services, &(&1.resource["service_id"] == service_id))
  end

  defp revision_source(service),
    do: %{"resource" => service.resource, "enabled" => service.enabled}

  defp list_result(operation, items, payload, key_fun) do
    bounded = sort_and_bound(items, key_fun)

    with {:ok, revision} <- Revision.calculate(list_resources(bounded)),
         {:ok, page} <- paginate(bounded, payload, key_fun),
         {:ok, observed_at} <- observation_time(),
         {:ok, result} <-
           validate_result(operation, %{
             "items" => list_resources(bounded),
             "revision" => revision,
             "observed_at" => observed_at
           }) do
      validate_result(operation, %{result | "items" => list_resources(page)})
    end
  end

  defp list_resources(items) do
    Enum.map(items, fn
      %{resource: resource} -> resource
      item -> item
    end)
  end

  defp sort_and_bound(items, key_fun) do
    items
    |> Enum.sort_by(key_fun)
    |> Enum.take(Bounds.max_list_entries())
  end

  defp paginate(items, payload, key_fun) do
    cursor = Map.get(payload, "cursor")
    limit = Map.get(payload, "limit", Bounds.max_list_entries())

    cond do
      not is_integer(limit) or limit < 1 or limit > Bounds.max_list_entries() ->
        invalid_error()

      not is_nil(cursor) and not is_binary(cursor) ->
        invalid_error()

      true ->
        page = if cursor, do: Enum.drop_while(items, &(key_fun.(&1) <= cursor)), else: items
        {:ok, Enum.take(page, limit)}
    end
  end

  defp cache_key(%{"name" => name, "type" => type, "values" => values}), do: {name, type, values}
  defp cache_key(_entry), do: {"", "", []}

  defp discovery_key(item), do: item["name"] <> "|" <> item["address"]

  defp observation_time do
    with {:ok, value} <- dependency_call(:clock, :utc_now, []),
         {:ok, timestamp} <- format_datetime(value) do
      {:ok, timestamp}
    end
  end

  defp format_datetime(%DateTime{utc_offset: 0, std_offset: 0} = value),
    do: {:ok, DateTime.to_iso8601(value)}

  defp format_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, _datetime, 0} -> {:ok, value}
      _ -> apply_failed_error()
    end
  end

  defp format_datetime(_value), do: apply_failed_error()

  defp validate_payload(operation_name, payload) do
    with {:ok, operation} <- ServerOperation.fetch(operation_name),
         {:ok, payload} <- Operation.validate_payload(operation, payload) do
      {:ok, payload}
    else
      _ -> invalid_error()
    end
  end

  defp validate_result(operation_name, result) do
    with {:ok, operation} <- ServerOperation.fetch(operation_name),
         {:ok, result} <- Operation.validate_result(operation, result) do
      {:ok, result}
    else
      _ -> invalid_error()
    end
  end

  defp dependency_call(key, function, arguments) do
    {:ok, apply(dependency_module(key), function, arguments)}
  rescue
    UndefinedFunctionError -> not_found_error()
    ArgumentError -> apply_failed_error()
    _exception -> apply_failed_error()
  catch
    :exit, :noproc -> not_found_error()
    :exit, {:noproc, _details} -> not_found_error()
    :exit, _reason -> apply_failed_error()
    _kind, _reason -> apply_failed_error()
  end

  defp dependency_module(key), do: Map.fetch!(dependencies(), key)

  defp owner_error(reason)
       when reason in [:registry_absent, :cache_absent, :not_found],
       do: not_found_error()

  defp owner_error(:already_exists), do: conflict_error()

  defp owner_error(reason)
       when reason in [
              :invalid_service_id,
              :invalid_service,
              :immutable_identity,
              :invalid_enabled,
              :invalid_snapshot
            ],
       do: invalid_error()

  defp owner_error(reason) when reason in [:persistence_failed, :apply_failed],
    do: apply_failed_error()

  defp owner_error(:rollback_failed), do: rollback_failed_error()
  defp owner_error(_reason), do: apply_failed_error()

  defp field(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end

  defp field(_map, _key), do: nil

  defp service_operation(:register), do: "server.mdns.services.register"
  defp service_operation(:update), do: "server.mdns.services.update"
  defp service_operation(:delete), do: "server.mdns.services.delete"
  defp service_operation(:toggle), do: "server.mdns.services.toggle"

  defp invalid_error, do: {:error, Error.new(:invalid, "invalid value", %{})}
  defp not_found_error, do: {:error, Error.new(:not_found, "resource not found", %{})}
  defp conflict_error, do: {:error, Error.new(:conflict, "operation conflict", %{})}
  defp unsupported_error, do: {:error, Error.new(:unsupported, "unsupported operation", %{})}
  defp apply_failed_error, do: {:error, Error.new(:apply_failed, "apply failed", %{})}
  defp rollback_failed_error, do: {:error, Error.new(:rollback_failed, "rollback failed", %{})}

  if @test_environment do
    defp dependencies do
      config = Application.get_env(:yellow_dog, __MODULE__, [])

      if Keyword.keyword?(config) and
           Enum.all?(config, fn {key, module} ->
             Map.has_key?(@production_dependencies, key) and is_atom(module) and
               not is_nil(module)
           end) do
        Map.merge(@production_dependencies, Map.new(config))
      else
        @production_dependencies
      end
    end
  else
    defp dependencies, do: @production_dependencies
  end
end
