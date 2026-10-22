defmodule YellowDog.Management.ApplicationAPI do
  @moduledoc "One authorized contract for Management queries and idempotent commands."
  alias YellowDog.Management.{Access, Caller, Domain, Limits, Operations, Queries}

  def query(caller, id, params), do: execute(caller, id, :query, params, nil)

  def command(caller, id, params, logical_key),
    do: execute(caller, id, :command, params, logical_key)

  @doc "Authorize server-built UI commands while preserving Domain validation receipts."
  def ui_command(%Caller{source: :ui} = caller, id, params, logical_key),
    do: execute(caller, id, :command, params, logical_key, :ui)

  def ui_command(_, _, _, _),
    do: {:error, %{code: "forbidden", message: "Verified UI caller required"}}

  def validate(schema, value) do
    root =
      JSV.build!(schema,
        default_meta: "https://json-schema.org/draft/2020-12/schema",
        resolver: JSV.Resolver.Internal,
        formats: false
      )

    case JSV.validate(value, root) do
      {:ok, validated} ->
        {:ok, validated}

      {:error, error} ->
        {:error,
         %{
           code: "invalid_request",
           message: "Parameters do not match the operation schema",
           details: %{
             "fields" =>
               locations(JSV.normalize_error(error, keys: :strings))
               |> Enum.uniq()
               |> Enum.take(20)
           }
         }}
    end
  end

  defp execute(caller, id, kind, params, logical_key, input_mode \\ :wire) do
    with {:ok, operation} <- Operations.get(id),
         :ok <- Access.authorize(caller, operation.scope),
         :ok <- correct_kind(operation.kind, kind),
         {:ok, params} <- validate_input(operation.input_schema, params, input_mode) do
      Limits.run(caller, id, fn ->
        result =
          case kind do
            :query -> Queries.run(id, params)
            :command -> mutate(caller, operation, params, logical_key)
          end

        with {:ok, data} <- result do
          data = project(operation, data)
          {:ok, if(kind == :query, do: validate_output!(operation, data), else: data)}
        end
      end)
    end
  end

  defp validate_input(schema, params, :wire), do: validate(schema, params)

  # LiveViews already construct finite canonical fields from route-owned identities
  # and parsed forms. Business errors must reach Domain's durable receipt boundary.
  defp validate_input(schema, params, :ui) when is_map(params) do
    if Map.keys(params) -- Map.keys(schema["properties"]) == [] do
      {:ok, params}
    else
      {:error, %{code: "invalid_request", message: "Unknown UI command fields"}}
    end
  end

  defp validate_input(_, _, :ui),
    do: {:error, %{code: "invalid_request", message: "Command parameters must be an object"}}

  defp mutate(caller, operation, params, logical_key) do
    with {:ok, key} <- Caller.request_key(caller, logical_key) do
      Domain.mutate(operation.domain_operation, params, Caller.actor(caller), key,
        caller: caller,
        scope: operation.scope,
        context: Caller.audit_context(caller),
        validate_result: fn data ->
          validate_output!(operation, project(operation, data))
          :ok
        end
      )
    end
  end

  defp validate_output!(operation, data) do
    case validate(operation.output_schema, data) do
      {:ok, output} ->
        output

      {:error, error} ->
        raise ArgumentError,
              "Management output violates #{operation.id} contract: #{inspect(error.details)}"
    end
  end

  defp correct_kind(kind, kind), do: :ok

  defp correct_kind(_, _),
    do: {:error, %{code: "invalid_request", message: "Operation has a different execution kind"}}

  defp project(%{id: "worker_update"}, data), do: Queries.worker_projection(data)
  defp project(%{id: "ip_database_sync"}, data), do: Queries.job_projection(data)

  defp project(%{id: "worker_target_publish"}, data),
    do: Map.put(data, "export_scope", Queries.export_scope())

  defp project(%{id: "task_update", output_schema: schema}, data),
    do: Map.take(data, Map.keys(schema["properties"]))

  defp project(_, data), do: Queries.json(data)

  defp locations(map) when is_map(map) do
    own =
      case map["instanceLocation"] do
        value when is_binary(value) -> [value]
        _ -> []
      end

    own ++ Enum.flat_map(Map.values(map), &locations/1)
  end

  defp locations(list) when is_list(list), do: Enum.flat_map(list, &locations/1)
  defp locations(_), do: []
end
