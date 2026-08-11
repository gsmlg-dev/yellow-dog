defmodule YellowDog.Console.NetmanManagement do
  @moduledoc """
  Typed console gateway for one concrete managed Netman runtime.

  LiveViews call the named functions generated below; operation names and
  envelope construction remain inside this boundary.
  """

  alias YellowDog.Console.ManagementResult
  alias YellowDog.ManagementCore
  alias YellowDog.Sync.Digest
  alias YellowDog.Sync.Error
  alias YellowDog.Sync.NetmanOperation

  @profiles_config_operation "netman.profiles.replace"
  @resolved_config_operation "netman.resolved.config.update"
  @resolved_rollback_operation "netman.resolved.config.rollback"
  @usable_config_states [:desired, :delivered, :applying, :applied]

  @operation_specs NetmanOperation.all()
                   |> Enum.map(fn {operation, metadata} ->
                     function =
                       operation
                       |> String.replace_prefix("netman.", "")
                       |> String.replace(".", "_")
                       |> String.to_atom()

                     %{
                       function: function,
                       operation: operation,
                       kind: metadata.kind,
                       snapshot_domain: String.replace(operation, "_", "-")
                     }
                   end)
                   |> Enum.sort_by(& &1.operation)

  @doc false
  def __operations__, do: @operation_specs

  @doc "Returns the latest durable Management-owned Netman profile configuration."
  def profiles_config(netman_id), do: latest_config(netman_id, @profiles_config_operation)

  @doc "Returns the latest durable Management-owned Resolved configuration."
  def resolved_config(netman_id) do
    result =
      with {:ok, versions} <- ManagementCore.list_config_versions() do
        versions
        |> Enum.filter(fn version ->
          version.target_type == :netman and version.target_id == netman_id and
            version.operation in [@resolved_config_operation, @resolved_rollback_operation] and
            version.state in @usable_config_states
        end)
        |> resolved_config_version(netman_id)
      end

    ManagementResult.normalize(result, source: :desired)
  end

  defp latest_config(netman_id, operation) do
    result =
      with {:ok, versions} <- ManagementCore.list_config_versions() do
        case Enum.find(versions, fn version ->
               version.target_type == :netman and version.target_id == netman_id and
                 version.operation == operation and
                 version.state in @usable_config_states
             end) do
          nil -> {:ok, nil}
          version -> ManagementCore.get_netman_config_version(netman_id, version.version)
        end
      end

    ManagementResult.normalize(result, source: :desired)
  end

  defp resolved_config_version([], _netman_id), do: {:ok, nil}

  defp resolved_config_version(
         [%{operation: @resolved_config_operation} = version | _versions],
         netman_id
       ),
       do: ManagementCore.get_netman_config_version(netman_id, version.version)

  defp resolved_config_version(
         [%{operation: @resolved_rollback_operation} = rollback_summary | versions],
         netman_id
       ) do
    with {:ok, rollback} <-
           ManagementCore.get_netman_config_version(netman_id, rollback_summary.version),
         %{"target_revision" => target_revision} <- rollback.payload,
         %{version: target_version} <-
           Enum.find(versions, fn version ->
             version.operation == @resolved_config_operation and
               version.applied_revision == target_revision
           end),
         {:ok, target} <- ManagementCore.get_netman_config_version(netman_id, target_version) do
      {:ok,
       %{
         operation: rollback.operation,
         state: rollback.state,
         version: rollback.version,
         payload: target.payload,
         applied_revision: rollback.applied_revision,
         expected_revision: rollback.expected_revision
       }}
    else
      nil -> {:error, Error.new(:invalid, "resolved rollback target is unavailable", %{})}
      {:error, %Error{}} = error -> error
      _invalid -> {:error, Error.new(:invalid, "resolved rollback target is unavailable", %{})}
    end
  end

  for %{function: function, operation: operation, kind: :query, snapshot_domain: domain} <-
        @operation_specs do
    @doc false
    def unquote(function)(netman_id, payload \\ %{}) do
      query(netman_id, unquote(domain), unquote(operation), payload)
    end
  end

  for %{function: function, operation: operation, kind: :command} <- @operation_specs do
    @doc false
    def unquote(function)(netman_id, payload, opts \\ []) do
      command(netman_id, unquote(operation), payload, opts)
    end
  end

  for %{function: function, operation: operation, kind: :config} <- @operation_specs do
    @doc false
    def unquote(function)(netman_id, payload, opts \\ []) do
      publish_config(netman_id, unquote(operation), payload, opts)
    end
  end

  defp query(netman_id, snapshot_domain, operation, payload) do
    with {:ok, snapshot_domain} <- snapshot_domain(snapshot_domain, payload) do
      case ManagementCore.query_netman(netman_id, snapshot_domain, operation, payload) do
        {:error, %Error{code: :not_connected} = offline} ->
          cached_query(netman_id, snapshot_domain, offline)

        result ->
          ManagementResult.normalize(result, source: :runtime)
      end
    else
      {:error, %Error{}} = error -> ManagementResult.normalize(error)
    end
  end

  defp cached_query(netman_id, snapshot_domain, offline) do
    case ManagementCore.get_netman_snapshot(netman_id, snapshot_domain) do
      {:ok, %{value: value, observed_at: observed_at} = snapshot} ->
        ManagementResult.normalize({:ok, value},
          source: :cache,
          observed_at: observed_at,
          snapshot: snapshot
        )

      {:error, %Error{code: :not_found}} ->
        ManagementResult.normalize({:error, offline})

      result ->
        ManagementResult.normalize(result)
    end
  end

  defp snapshot_domain(domain, payload) do
    with {:ok, digest} <- Digest.calculate(payload) do
      {first, second} = String.split_at(digest, 32)
      {:ok, Enum.join([domain, first, second], ".")}
    end
  end

  defp command(netman_id, operation, payload, opts) when is_list(opts) do
    netman_id
    |> ManagementCore.command_netman(
      operation,
      payload,
      Keyword.get(opts, :expected_revision),
      Keyword.get(opts, :idempotency_key)
    )
    |> ManagementResult.normalize(source: :runtime)
  end

  defp command(_netman_id, _operation, _payload, _opts), do: invalid_options()

  defp publish_config(netman_id, operation, payload, opts) when is_list(opts) do
    netman_id
    |> ManagementCore.publish_netman_config(%{
      operation: operation,
      payload: payload,
      expected_revision: Keyword.get(opts, :expected_revision)
    })
    |> ManagementResult.normalize(source: :desired)
  end

  defp publish_config(_netman_id, _operation, _payload, _opts), do: invalid_options()

  defp invalid_options do
    {:error, Error.new(:invalid, "invalid management options", %{})}
    |> ManagementResult.normalize()
  end
end
