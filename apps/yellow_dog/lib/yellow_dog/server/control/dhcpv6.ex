defmodule YellowDog.Server.Control.Dhcpv6 do
  @moduledoc false

  alias YellowDog.Server.Control.Revision
  alias YellowDog.Sync.Bounds
  alias YellowDog.Sync.Error
  alias YellowDog.Sync.Operation
  alias YellowDog.Sync.ServerOperation

  @validation_observed_at "1970-01-01T00:00:00Z"
  @validation_revision String.duplicate("0", 64)
  @pool_mutations [
    "server.dhcp.pools.create",
    "server.dhcp.pools.update",
    "server.dhcp.pools.delete",
    "server.dhcp.pools.force_delete"
  ]
  @mutation_operations @pool_mutations ++ ["server.dhcp.leases.release"]
  @production_dependencies %{
    pool_store: Module.concat(["YellowDog", "Dhcpv6", "PoolStore"]),
    lease_manager: Module.concat(["YellowDog", "Dhcpv6", "LeaseManager"]),
    clock: DateTime
  }
  @test_environment Mix.env() == :test

  @spec dispatch(String.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def dispatch("server.dhcp.pools.list", payload), do: list_pools(payload)
  def dispatch("server.dhcp.leases.list", payload), do: list_leases(payload)
  def dispatch("server.dhcp.activity.list", payload), do: unsupported_activity(payload)
  def dispatch("server.dhcp.status.get", payload), do: status(payload)
  def dispatch("server.dhcp.pools.create", payload), do: mutate_pool(:create, payload)
  def dispatch("server.dhcp.pools.update", payload), do: mutate_pool(:update, payload)
  def dispatch("server.dhcp.pools.delete", payload), do: mutate_pool(:delete, payload)
  def dispatch("server.dhcp.pools.force_delete", payload), do: mutate_pool(:force_delete, payload)
  def dispatch("server.dhcp.leases.release", payload), do: release_lease(payload)
  def dispatch(_operation, _payload), do: unsupported_error()

  @spec current(String.t(), map()) :: {:ok, map() | :missing} | {:error, Error.t()}
  def current(operation, payload) when operation in @pool_mutations do
    with {:ok, payload} <- validate_ipv6_payload(operation, payload),
         {:ok, pools} <- durable_pool_snapshot(),
         {:ok, resources} <- project_pools(pools) do
      current_pool(operation, payload["pool_id"], resources)
    end
  end

  def current("server.dhcp.leases.release", payload) do
    with {:ok, payload} <- validate_ipv6_payload("server.dhcp.leases.release", payload),
         {:ok, leases} <- manager_call(:control_list_leases, []),
         {:ok, resources} <- project_leases(leases),
         resource when not is_nil(resource) <-
           Enum.find(resources, &(&1["lease_id"] == payload["lease_id"])) do
      {:ok, resource}
    else
      nil -> not_found_error()
      {:error, %Error{}} = error -> error
    end
  end

  def current(operation, _payload) when operation in @mutation_operations, do: invalid_error()
  def current(_operation, _payload), do: unsupported_error()

  defp list_pools(payload) do
    with {:ok, payload} <- validate_ipv6_payload("server.dhcp.pools.list", payload),
         {:ok, pools} <- durable_pool_snapshot(),
         {:ok, resources} <- project_pools(pools) do
      list_result("server.dhcp.pools.list", resources, payload, & &1["pool_id"])
    end
  end

  defp list_leases(payload) do
    with {:ok, payload} <- validate_ipv6_payload("server.dhcp.leases.list", payload),
         {:ok, leases} <- manager_call(:control_list_leases, []),
         {:ok, resources} <- project_leases(leases) do
      list_result("server.dhcp.leases.list", resources, payload, & &1["lease_id"])
    end
  end

  defp unsupported_activity(payload) do
    with {:ok, _payload} <- validate_ipv6_payload("server.dhcp.activity.list", payload) do
      unsupported_error()
    end
  end

  defp status(payload) do
    with {:ok, _payload} <- validate_ipv6_payload("server.dhcp.status.get", payload),
         {:ok, state} <- manager_call(:control_status, []),
         {:ok, status} <- project_status(state),
         {:ok, result} <-
           validate_operation_result("server.dhcp.status.get", %{
             "family" => "ipv6",
             "status" => status
           }) do
      {:ok, result}
    end
  end

  defp mutate_pool(action, payload) do
    operation = pool_operation(action)

    with {:ok, payload} <- validate_ipv6_payload(operation, payload),
         {:ok, persisted_snapshot} <- durable_pool_snapshot(),
         {:ok, runtime_snapshot} <- manager_call(:control_pool_snapshot, []),
         {:ok, resources} <- project_pools(persisted_snapshot),
         {:ok, candidate, result_resource} <-
           pool_candidate(action, payload, persisted_snapshot, resources),
         :ok <- validate_candidate(action, result_resource),
         :ok <- persist_and_apply(persisted_snapshot, runtime_snapshot, candidate) do
      pool_mutation_result(action, result_resource)
    end
  end

  defp release_lease(payload) do
    with {:ok, payload} <- validate_ipv6_payload("server.dhcp.leases.release", payload),
         {:ok, lease} <- manager_call(:control_release_lease, [payload["lease_id"]]),
         {:ok, resource} <- project_lease(lease),
         {:ok, result} <-
           validate_operation_result("server.dhcp.leases.release", %{
             "family" => "ipv6",
             "lease_id" => resource["lease_id"],
             "address" => resource["address"],
             "released" => true
           }) do
      {:ok, result}
    end
  end

  defp pool_candidate(:create, payload, pools, resources) do
    if Enum.any?(resources, &(&1["pool_id"] == payload["pool_id"])) do
      conflict_error()
    else
      with {:ok, resource} <- project_pool(pool_config(payload)) do
        {:ok, pools ++ [pool_config(resource)], resource}
      end
    end
  end

  defp pool_candidate(:update, payload, pools, resources) do
    if Enum.any?(resources, &(&1["pool_id"] == payload["pool_id"])) do
      with {:ok, resource} <- project_pool(pool_config(payload)) do
        {:ok,
         Enum.map(pools, fn pool ->
           if pool_name(pool) == payload["pool_id"], do: pool_config(resource), else: pool
         end), resource}
      end
    else
      not_found_error()
    end
  end

  defp pool_candidate(action, payload, pools, resources)
       when action in [:delete, :force_delete] do
    with resource when not is_nil(resource) <-
           Enum.find(resources, &(&1["pool_id"] == payload["pool_id"])),
         :ok <- active_lease_guard(action, payload["pool_id"]) do
      {:ok, Enum.reject(pools, &(pool_name(&1) == payload["pool_id"])), resource}
    else
      nil -> not_found_error()
      {:error, %Error{}} = error -> error
    end
  end

  defp active_lease_guard(:force_delete, _pool_id), do: :ok

  defp active_lease_guard(:delete, pool_id) do
    with {:ok, true} <- manager_call(:control_pool_has_active_leases?, [pool_id]) do
      conflict_error()
    else
      {:ok, false} -> :ok
      {:error, %Error{}} = error -> error
    end
  end

  defp validate_candidate(action, resource) when action in [:create, :update],
    do: pool_store_call(:control_validate_pool, [pool_config(resource)])

  defp validate_candidate(_action, _resource), do: :ok

  defp persist_and_apply(persisted_snapshot, runtime_snapshot, candidate) do
    case pool_store_call(:control_persist_snapshot, [candidate]) do
      :ok ->
        case manager_call(:control_apply_pool_snapshot, [candidate]) do
          :ok -> :ok
          {:error, %Error{}} -> rollback(persisted_snapshot, runtime_snapshot)
        end

      {:error, %Error{}} = error ->
        error
    end
  end

  defp rollback(persisted_snapshot, runtime_snapshot) do
    persisted = pool_store_call(:control_persist_snapshot, [persisted_snapshot])
    restored = manager_call(:control_apply_pool_snapshot, [runtime_snapshot])

    if persisted == :ok and restored == :ok,
      do: apply_failed_error(),
      else: rollback_failed_error()
  end

  defp pool_mutation_result(action, resource) when action in [:create, :update] do
    with {:ok, revision} <- Revision.calculate(resource),
         {:ok, result} <-
           validate_operation_result(pool_operation(action), %{
             "resource_type" => "dhcp_pool",
             "resource_id" => resource["pool_id"],
             "revision" => revision,
             "resource" => resource
           }) do
      {:ok, result}
    end
  end

  defp pool_mutation_result(action, resource) when action in [:delete, :force_delete] do
    ref = %{"family" => "ipv6", "pool_id" => resource["pool_id"]}

    with {:ok, revision} <- Revision.calculate(ref),
         {:ok, result} <-
           validate_operation_result(pool_operation(action), %{
             "resource_type" => "dhcp_pool",
             "resource_id" => resource["pool_id"],
             "revision" => revision,
             "resource_ref" => ref
           }) do
      {:ok, result}
    end
  end

  defp current_pool("server.dhcp.pools.create", pool_id, resources) do
    case Enum.find(resources, &(&1["pool_id"] == pool_id)) do
      nil -> {:ok, :missing}
      resource -> validate_pool_resource(resource)
    end
  end

  defp current_pool(_operation, pool_id, resources) do
    case Enum.find(resources, &(&1["pool_id"] == pool_id)) do
      nil -> not_found_error()
      resource -> validate_pool_resource(resource)
    end
  end

  defp durable_pool_snapshot do
    with {:ok, pools} <- pool_store_call(:control_snapshot, []),
         true <- is_list(pools) do
      {:ok, pools}
    else
      false -> apply_failed_error()
      {:error, %Error{}} = error -> error
    end
  end

  defp project_pools(pools) when is_list(pools) do
    pools
    |> Enum.reduce_while({:ok, []}, fn pool, {:ok, resources} ->
      case project_pool(pool) do
        {:ok, resource} -> {:cont, {:ok, [resource | resources]}}
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, resources} -> {:ok, Enum.reverse(resources)}
      {:error, %Error{}} = error -> error
    end
  end

  defp project_pools(_pools), do: invalid_error()

  defp project_pool(pool) when is_map(pool) do
    with preferred when is_integer(preferred) <- pool_field(pool, :preferred_lifetime),
         valid when is_integer(valid) <- pool_field(pool, :valid_lifetime),
         true <- preferred == valid,
         {:ok, subnet} <- canonical_subnet(pool_field(pool, :network)),
         {:ok, start_address} <- canonical_address(pool_field(pool, :range_start)),
         {:ok, end_address} <- canonical_address(pool_field(pool, :range_end)) do
      resource = %{
        "family" => "ipv6",
        "pool_id" => pool_name(pool),
        "subnet" => subnet,
        "start_address" => start_address,
        "end_address" => end_address,
        "lease_seconds" => preferred
      }

      validate_pool_resource(resource)
    else
      false -> unsupported_error()
      _ -> invalid_error()
    end
  end

  defp project_pool(_pool), do: invalid_error()

  defp project_leases(leases) when is_list(leases) do
    leases
    |> Enum.reduce_while({:ok, []}, fn lease, {:ok, resources} ->
      case project_lease(lease) do
        {:ok, resource} -> {:cont, {:ok, [resource | resources]}}
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, resources} -> {:ok, Enum.reverse(resources)}
      {:error, %Error{}} = error -> error
    end
  end

  defp project_leases(_leases), do: invalid_error()

  defp project_lease(lease) when is_map(lease) do
    with {:ok, address} <- canonical_address(lease_field(lease, :address)),
         state <- lease_state(lease_field(lease, :state)) do
      resource = %{
        "family" => "ipv6",
        "lease_id" => lease_field(lease, :lease_id),
        "address" => address,
        "state" => state
      }

      validation = %{
        "items" => [resource],
        "revision" => @validation_revision,
        "observed_at" => @validation_observed_at
      }

      case validate_operation_result("server.dhcp.leases.list", validation) do
        {:ok, _} -> {:ok, resource}
        {:error, %Error{}} = error -> error
      end
    else
      _ -> invalid_error()
    end
  end

  defp project_lease(_lease), do: invalid_error()

  defp project_status(state) when state in [:running, :stopped, :failed],
    do: {:ok, Atom.to_string(state)}

  defp project_status(state) when state in ["running", "stopped", "failed"], do: {:ok, state}
  defp project_status(_state), do: apply_failed_error()

  defp list_result(operation, items, payload, id_fun) do
    sorted = items |> Enum.sort_by(id_fun) |> Enum.take(Bounds.max_list_entries())

    with {:ok, revision} <- Revision.calculate(sorted),
         {:ok, observed_at} <- observation_time(),
         {:ok, result} <-
           validate_operation_result(operation, %{
             "items" => sorted,
             "revision" => revision,
             "observed_at" => observed_at
           }) do
      validate_operation_result(operation, %{
        result
        | "items" => paginate(sorted, payload, id_fun)
      })
    end
  end

  defp paginate(items, payload, id_fun) do
    cursor = Map.get(payload, "cursor")
    limit = Map.get(payload, "limit", Bounds.max_list_entries())
    values = if cursor, do: Enum.drop_while(items, &(id_fun.(&1) <= cursor)), else: items
    Enum.take(values, limit)
  end

  defp observation_time do
    case apply(dependency_module(:clock), :utc_now, []) do
      %DateTime{utc_offset: 0, std_offset: 0} = value -> {:ok, DateTime.to_iso8601(value)}
      {:ok, %DateTime{utc_offset: 0, std_offset: 0} = value} -> {:ok, DateTime.to_iso8601(value)}
      _ -> apply_failed_error()
    end
  rescue
    _exception -> apply_failed_error()
  end

  defp validate_ipv6_payload(operation_name, payload) do
    with {:ok, operation} <- ServerOperation.fetch(operation_name),
         {:ok, validated} <- Operation.validate_payload(operation, payload),
         "ipv6" <- validated["family"] do
      {:ok, validated}
    else
      _ -> invalid_error()
    end
  end

  defp validate_operation_result(operation_name, result) do
    with {:ok, operation} <- ServerOperation.fetch(operation_name),
         {:ok, validated} <- Operation.validate_result(operation, result) do
      {:ok, validated}
    else
      _ -> invalid_error()
    end
  end

  defp validate_pool_resource(resource) do
    validation = %{
      "items" => [resource],
      "revision" => @validation_revision,
      "observed_at" => @validation_observed_at
    }

    case validate_operation_result("server.dhcp.pools.list", validation) do
      {:ok, _} -> {:ok, resource}
      _ -> invalid_error()
    end
  end

  defp pool_store_call(function, arguments), do: dependency_call(:pool_store, function, arguments)
  defp manager_call(function, arguments), do: dependency_call(:lease_manager, function, arguments)

  defp dependency_call(key, function, arguments) do
    case apply(dependency_module(key), function, arguments) do
      :ok -> :ok
      {:ok, _value} = result -> result
      {:error, :not_found} -> not_found_error()
      {:error, :manager_absent} -> not_found_error()
      {:error, :has_active_leases} -> conflict_error()
      {:error, :unrepresentable_lifetime} -> unsupported_error()
      {:error, :invalid} -> invalid_error()
      {:error, _reason} -> apply_failed_error()
      _ -> apply_failed_error()
    end
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
  defp pool_operation(:create), do: "server.dhcp.pools.create"
  defp pool_operation(:update), do: "server.dhcp.pools.update"
  defp pool_operation(:delete), do: "server.dhcp.pools.delete"
  defp pool_operation(:force_delete), do: "server.dhcp.pools.force_delete"

  defp pool_config(resource) do
    %{
      name: resource["pool_id"],
      network: resource["subnet"],
      range_start: resource["start_address"],
      range_end: resource["end_address"],
      preferred_lifetime: resource["lease_seconds"],
      valid_lifetime: resource["lease_seconds"]
    }
  end

  defp pool_name(pool), do: pool_field(pool, :name)
  defp pool_field(pool, key), do: Map.get(pool, key, Map.get(pool, Atom.to_string(key)))
  defp lease_field(lease, key), do: Map.get(lease, key, Map.get(lease, Atom.to_string(key)))

  defp canonical_subnet(subnet) when is_binary(subnet) do
    with [address, prefix] <- String.split(subnet, "/", parts: 2),
         {prefix, ""} <- Integer.parse(prefix),
         true <- prefix in 0..128,
         {:ok, address} <- canonical_address(address) do
      {:ok, address <> "/" <> Integer.to_string(prefix)}
    else
      _ -> :error
    end
  end

  defp canonical_subnet(_subnet), do: :error

  defp canonical_address(address) when is_binary(address) do
    case :inet.parse_ipv6_address(String.to_charlist(address)) do
      {:ok, address} -> {:ok, address |> :inet.ntoa() |> List.to_string() |> String.downcase()}
      _ -> :error
    end
  end

  defp canonical_address(address) when is_tuple(address) and tuple_size(address) == 8,
    do: {:ok, address |> :inet.ntoa() |> List.to_string() |> String.downcase()}

  defp canonical_address(_address), do: :error

  defp lease_state(state) when state in [:active, :expired, :released], do: Atom.to_string(state)
  defp lease_state(state) when state in ["active", "expired", "released"], do: state
  defp lease_state(_state), do: nil

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
           Enum.all?(Keyword.keys(config), &Map.has_key?(@production_dependencies, &1)) do
        Map.merge(@production_dependencies, Map.new(config))
      else
        @production_dependencies
      end
    end
  else
    defp dependencies, do: @production_dependencies
  end
end
