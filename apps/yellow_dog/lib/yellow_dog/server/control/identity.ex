defmodule YellowDog.Server.Control.Identity do
  @moduledoc false

  alias YellowDog.Server.Control.Revision
  alias YellowDog.Sync.Bounds
  alias YellowDog.Sync.Error
  alias YellowDog.Sync.Operation
  alias YellowDog.Sync.ServerOperation

  @validation_observed_at "1970-01-01T00:00:00Z"
  @validation_revision String.duplicate("0", 64)
  @unsupported_operations [
    "server.identity.approvals.list",
    "server.identity.tokens.list",
    "server.identity.policies.get",
    "server.identity.tokens.create",
    "server.identity.tokens.revoke",
    "server.identity.policies.update"
  ]
  @unsupported_mutations [
    "server.identity.tokens.create",
    "server.identity.tokens.revoke",
    "server.identity.policies.update"
  ]
  @host_mutations [
    "server.identity.hosts.approve",
    "server.identity.hosts.revoke",
    "server.identity.hosts.delete"
  ]
  @production_dependencies %{
    identity: Module.concat(["YellowDogIdentity"]),
    clock: DateTime
  }
  @test_environment Mix.env() == :test

  @spec dispatch(String.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def dispatch("server.identity.hosts.list", payload), do: list_hosts(payload)
  def dispatch("server.identity.audit.list", payload), do: list_audit(payload)

  def dispatch(operation, payload) when operation in @unsupported_operations,
    do: unsupported(operation, payload)

  def dispatch("server.identity.hosts.approve", payload),
    do: mutate_host(:approve, payload)

  def dispatch("server.identity.hosts.revoke", payload),
    do: mutate_host(:revoke, payload)

  def dispatch("server.identity.hosts.delete", payload),
    do: delete_host(payload)

  def dispatch(_operation, _payload), do: unsupported_error()

  @spec current(String.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def current(operation, payload) when operation in @host_mutations do
    with {:ok, payload} <- validate_payload(operation, payload),
         {:ok, resource} <- owner_host(payload["host_id"]),
         true <- resource["host_id"] == payload["host_id"] do
      {:ok, resource}
    else
      false -> invalid_error()
      {:error, %Error{}} = error -> error
    end
  end

  def current(operation, payload) when operation in @unsupported_mutations,
    do: unsupported(operation, payload)

  def current(_operation, _payload), do: unsupported_error()

  defp list_hosts(payload) do
    operation = "server.identity.hosts.list"

    with {:ok, payload} <- validate_payload(operation, payload),
         {:ok, hosts} <- owner_list(:control_list_hosts),
         {:ok, resources} <- validate_items(hosts, &validate_host/1) do
      list_result(operation, resources, payload, & &1["host_id"])
    end
  end

  defp list_audit(payload) do
    operation = "server.identity.audit.list"

    with {:ok, payload} <- validate_payload(operation, payload),
         {:ok, entries} <- owner_list(:control_list_audit),
         {:ok, resources} <-
           validate_items(entries, &validate_audit/1) do
      list_result(operation, resources, payload, & &1["audit_id"])
    end
  end

  defp mutate_host(action, payload) do
    operation = host_operation(action)

    with {:ok, payload} <- validate_payload(operation, payload),
         {:ok, result} <-
           dependency_call(:identity, host_owner_function(action), [payload["host_id"]]),
         {:ok, prior, resulting} <- owner_host_mutation(result),
         :ok <- validate_transition(action, payload["host_id"], prior, resulting) do
      revisioned_result(operation, resulting)
    end
  end

  defp delete_host(payload) do
    operation = "server.identity.hosts.delete"

    with {:ok, payload} <- validate_payload(operation, payload),
         {:ok, result} <-
           dependency_call(:identity, :control_delete_host, [payload["host_id"]]),
         {:ok, prior} <- owner_deleted_host(result),
         true <- prior["host_id"] == payload["host_id"] do
      deleted_result(operation, prior)
    else
      false -> invalid_error()
      {:error, %Error{}} = error -> error
    end
  end

  defp unsupported(operation, payload) do
    with {:ok, _payload} <- validate_payload(operation, payload) do
      unsupported_error()
    end
  end

  defp owner_list(function) do
    case dependency_call(:identity, function, []) do
      {:ok, {:ok, items}} when is_list(items) -> {:ok, items}
      {:ok, {:error, reason}} -> owner_error(reason)
      {:ok, _result} -> apply_failed_error()
      {:error, %Error{}} = error -> error
    end
  end

  defp owner_host(host_id) do
    case dependency_call(:identity, :control_host, [host_id]) do
      {:ok, {:ok, resource}} -> validate_host(resource)
      {:ok, {:error, reason}} -> owner_error(reason)
      {:ok, _result} -> apply_failed_error()
      {:error, %Error{}} = error -> error
    end
  end

  defp owner_host_mutation({:ok, prior, resulting}) do
    with {:ok, prior} <- validate_host(prior),
         {:ok, resulting} <- validate_host(resulting) do
      {:ok, prior, resulting}
    end
  end

  defp owner_host_mutation({:error, reason}), do: owner_error(reason)
  defp owner_host_mutation(_result), do: apply_failed_error()

  defp owner_deleted_host({:ok, prior}), do: validate_host(prior)
  defp owner_deleted_host({:error, reason}), do: owner_error(reason)
  defp owner_deleted_host(_result), do: apply_failed_error()

  defp validate_transition(:approve, host_id, prior, resulting) do
    validate_transition(host_id, prior, resulting, ["pending"], "approved")
  end

  defp validate_transition(:revoke, host_id, prior, resulting) do
    validate_transition(host_id, prior, resulting, ["pending", "approved"], "revoked")
  end

  defp validate_transition(host_id, prior, resulting, prior_states, resulting_state) do
    if prior["host_id"] == host_id and resulting["host_id"] == host_id and
         prior["name"] == resulting["name"] and prior["state"] in prior_states and
         resulting["state"] == resulting_state do
      :ok
    else
      invalid_error()
    end
  end

  defp validate_items(items, validator) when is_list(items) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, validated} ->
      case validator.(item) do
        {:ok, item} -> {:cont, {:ok, [item | validated]}}
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, validated} -> {:ok, Enum.reverse(validated)}
      {:error, %Error{}} = error -> error
    end
  end

  defp validate_items(_items, _validator), do: apply_failed_error()

  defp validate_host(resource) do
    validation = %{
      "items" => [resource],
      "revision" => @validation_revision,
      "observed_at" => @validation_observed_at
    }

    with {:ok, %{"items" => [resource]}} <-
           validate_result("server.identity.hosts.list", validation),
         {:ok, revision} <- Revision.calculate(resource),
         true <- resource["revision"] == revision do
      {:ok, resource}
    else
      _ -> invalid_error()
    end
  end

  defp validate_audit(resource) do
    validation = %{
      "items" => [resource],
      "revision" => @validation_revision,
      "observed_at" => @validation_observed_at
    }

    case validate_result("server.identity.audit.list", validation) do
      {:ok, %{"items" => [resource]}} -> {:ok, resource}
      _ -> invalid_error()
    end
  end

  defp list_result(operation, items, payload, id_fun) do
    with :ok <- validate_unique_ids(items, id_fun),
         bounded <-
           items
           |> Enum.sort_by(id_fun)
           |> Enum.take(Bounds.max_list_entries()),
         {:ok, revision} <- Revision.calculate(bounded),
         page <- paginate(bounded, payload, id_fun),
         {:ok, observed_at} <- observation_time(),
         result = %{
           "items" => page,
           "revision" => revision,
           "observed_at" => observed_at
         },
         {:ok, result} <- validate_result(operation, result) do
      {:ok, result}
    end
  end

  defp validate_unique_ids(items, id_fun) do
    if length(items) == length(Enum.uniq_by(items, id_fun)),
      do: :ok,
      else: invalid_error()
  end

  defp paginate(items, payload, id_fun) do
    cursor = Map.get(payload, "cursor")
    limit = Map.get(payload, "limit", 100)
    page = if cursor, do: Enum.drop_while(items, &(id_fun.(&1) <= cursor)), else: items
    Enum.take(page, limit)
  end

  defp revisioned_result(operation, resource) do
    result = %{
      "resource_type" => "identity_host",
      "resource_id" => resource["host_id"],
      "revision" => resource["revision"],
      "resource" => resource
    }

    validate_result(operation, result)
  end

  defp deleted_result(operation, prior) do
    result = %{
      "resource_type" => "identity_host",
      "resource_id" => prior["host_id"],
      "revision" => prior["revision"],
      "resource_ref" => %{"host_id" => prior["host_id"]}
    }

    validate_result(operation, result)
  end

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
    with {:ok, dependencies} <- dependencies(),
         {:ok, module} <- Map.fetch(dependencies, key),
         {:module, ^module} <- Code.ensure_loaded(module),
         true <- function_exported?(module, function, length(arguments)) do
      invoke_dependency(module, function, arguments)
    else
      false -> not_found_error()
      :error -> not_found_error()
      {:error, :nofile} -> not_found_error()
      {:error, %Error{}} = error -> error
      _ -> apply_failed_error()
    end
  rescue
    _exception -> apply_failed_error()
  catch
    _kind, _reason -> apply_failed_error()
  end

  defp invoke_dependency(module, function, arguments) do
    {:ok, apply(module, function, arguments)}
  rescue
    _exception -> apply_failed_error()
  catch
    :exit, :noproc -> not_found_error()
    :exit, {:noproc, _details} -> not_found_error()
    _kind, _reason -> apply_failed_error()
  end

  defp owner_error(reason)
       when reason in [:not_found, :noproc, :owner_absent, :registry_absent],
       do: not_found_error()

  defp owner_error({:noproc, _details}), do: not_found_error()

  defp owner_error(reason) when reason in [:conflict, :already_revoked],
    do: conflict_error()

  defp owner_error({:invalid_status, _status}), do: conflict_error()
  defp owner_error(:invalid), do: invalid_error()
  defp owner_error(:unsupported), do: unsupported_error()

  defp owner_error(reason) when reason in [:persistence_failed, :apply_failed],
    do: apply_failed_error()

  defp owner_error(_reason), do: apply_failed_error()

  defp host_operation(:approve), do: "server.identity.hosts.approve"
  defp host_operation(:revoke), do: "server.identity.hosts.revoke"
  defp host_owner_function(:approve), do: :control_approve_host
  defp host_owner_function(:revoke), do: :control_revoke_host

  defp invalid_error, do: {:error, Error.new(:invalid, "invalid value", %{})}
  defp not_found_error, do: {:error, Error.new(:not_found, "resource not found", %{})}
  defp conflict_error, do: {:error, Error.new(:conflict, "operation conflict", %{})}
  defp unsupported_error, do: {:error, Error.new(:unsupported, "unsupported operation", %{})}
  defp apply_failed_error, do: {:error, Error.new(:apply_failed, "apply failed", %{})}

  if @test_environment do
    defp dependencies do
      config = Application.get_env(:yellow_dog, __MODULE__, [])

      if Keyword.keyword?(config) and
           Enum.all?(config, fn {key, module} ->
             Map.has_key?(@production_dependencies, key) and is_atom(module) and
               not is_nil(module)
           end) do
        {:ok, Map.merge(@production_dependencies, Map.new(config))}
      else
        apply_failed_error()
      end
    end
  else
    defp dependencies, do: {:ok, @production_dependencies}
  end
end
