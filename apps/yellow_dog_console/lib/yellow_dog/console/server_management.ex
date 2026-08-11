defmodule YellowDog.Console.ServerManagement do
  @moduledoc """
  Typed console gateway for one concrete managed Server.

  LiveViews call the named functions generated below; operation names and
  envelope construction remain inside this boundary.
  """

  alias YellowDog.Console.ManagementResult
  alias YellowDog.ManagementCore
  alias YellowDog.Sync.Digest
  alias YellowDog.Sync.Error
  alias YellowDog.Sync.ServerOperation

  @operation_specs ServerOperation.all()
                   |> Enum.map(fn {operation, metadata} ->
                     function =
                       operation
                       |> String.replace_prefix("server.", "")
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

  @doc "Returns the Management-owned aggregate configuration draft for one Server."
  def get_config_draft(server_id) do
    server_id
    |> ManagementCore.get_server_config()
    |> ManagementResult.normalize(source: :desired)
  end

  @doc "Replaces one Server's aggregate draft using its independent draft CAS revision."
  def put_config_draft(server_id, expected_draft_revision, document) do
    server_id
    |> ManagementCore.put_server_config(expected_draft_revision, document)
    |> ManagementResult.normalize(source: :desired)
  end

  @doc "Publishes the exact aggregate document stored at a Server draft revision."
  def publish_config_draft(server_id, expected_draft_revision) do
    server_id
    |> ManagementCore.publish_server_config(expected_draft_revision)
    |> ManagementResult.normalize(source: :desired)
  end

  @doc "Republishes a previous aggregate document as a new monotonic version."
  def rollback_config(server_id, version, expected_draft_revision) do
    server_id
    |> ManagementCore.rollback_server_config(version, expected_draft_revision)
    |> ManagementResult.normalize(source: :desired)
  end

  @doc "Lists aggregate configuration lifecycle summaries for one Server."
  def config_versions(server_id) do
    result =
      case ManagementCore.list_config_versions() do
        {:ok, versions} ->
          {:ok,
           Enum.filter(versions, fn version ->
             version.target_type == :server and version.target_id == server_id and
               version.operation == "server.config.replace"
           end)}

        error ->
          error
      end

    ManagementResult.normalize(result, source: :desired)
  end

  for %{function: function, operation: operation, kind: :query, snapshot_domain: domain} <-
        @operation_specs do
    @doc false
    def unquote(function)(server_id, payload \\ %{}) do
      query(server_id, unquote(domain), unquote(operation), payload)
    end
  end

  for %{function: function, operation: operation, kind: :command} <- @operation_specs do
    @doc false
    def unquote(function)(server_id, payload, opts \\ []) do
      command(server_id, unquote(operation), payload, opts)
    end
  end

  for %{function: function, operation: operation, kind: :config} <- @operation_specs do
    @doc false
    def unquote(function)(server_id, payload, opts \\ []) do
      publish_config(server_id, unquote(operation), payload, opts)
    end
  end

  defp query(server_id, snapshot_domain, operation, payload) do
    with {:ok, snapshot_domain} <- snapshot_domain(snapshot_domain, payload) do
      case ManagementCore.query_server(server_id, snapshot_domain, operation, payload) do
        {:error, %Error{code: :not_connected} = offline} ->
          cached_query(server_id, snapshot_domain, offline)

        result ->
          ManagementResult.normalize(result, source: :runtime)
      end
    else
      {:error, %Error{}} = error -> ManagementResult.normalize(error)
    end
  end

  defp cached_query(server_id, snapshot_domain, offline) do
    case ManagementCore.get_server_snapshot(server_id, snapshot_domain) do
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

  defp command(server_id, operation, payload, opts) when is_list(opts) do
    server_id
    |> ManagementCore.command_server(
      operation,
      payload,
      Keyword.get(opts, :expected_revision),
      Keyword.get(opts, :idempotency_key)
    )
    |> ManagementResult.normalize(source: :runtime)
  end

  defp command(_server_id, _operation, _payload, _opts), do: invalid_options()

  defp publish_config(server_id, operation, payload, opts) when is_list(opts) do
    server_id
    |> ManagementCore.publish_server_config(%{
      operation: operation,
      payload: payload,
      expected_revision: Keyword.get(opts, :expected_revision)
    })
    |> ManagementResult.normalize(source: :desired)
  end

  defp publish_config(_server_id, _operation, _payload, _opts), do: invalid_options()

  defp invalid_options do
    {:error, Error.new(:invalid, "invalid management options", %{})}
    |> ManagementResult.normalize()
  end
end
