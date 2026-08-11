defmodule YellowDog.Management.ServerConfigs do
  @moduledoc """
  Durable Management-owned aggregate configuration drafts for Servers.

  Draft revisions provide editing CAS only. Runtime configuration revisions
  remain owned by `YellowDog.Management.ConfigVersions`.
  """

  alias YellowDog.Management.ConfigVersions
  alias YellowDog.Management.EventStore
  alias YellowDog.Management.ManifestStore
  alias YellowDog.Management.Servers
  alias YellowDog.Management.Storage.AtomicJson
  alias YellowDog.Management.Storage.Path, as: StoragePath
  alias YellowDog.Sync.Error
  alias YellowDog.Sync.Operation

  @section "server_config_draft"
  @section_keys Enum.sort(~w(document draft_revision schema_version))
  @max_revision 9_223_372_036_854_775_807
  @operation "server.config.replace"

  @type draft :: %{
          server_id: String.t(),
          draft_revision: non_neg_integer(),
          document: map() | nil
        }

  @doc "Fetches the current durable aggregate draft for a registered Server."
  @spec get(term()) :: {:ok, draft()} | {:error, Error.t()}
  def get(server_id) do
    with {:ok, server} <- registered_server(server_id),
         {:ok, path} <- StoragePath.server_manifest(server.id),
         {:ok, manifest} <- read_manifest(path),
         {:ok, draft} <- decode_section(Map.get(manifest, @section), server.id) do
      {:ok, draft}
    end
  end

  @doc "Replaces the complete aggregate draft using its independent CAS revision."
  @spec put(term(), term(), term()) :: {:ok, draft()} | {:error, Error.t()}
  def put(server_id, expected_draft_revision, document) do
    with {:ok, server} <- registered_server(server_id),
         :ok <- validate_revision(expected_draft_revision),
         {:ok, document} <- validate_document(document),
         {:ok, path} <- StoragePath.server_manifest(server.id) do
      ManifestStore.commit_section(path, @section, fn current_section ->
        with {:ok, current} <- decode_section(current_section, server.id),
             :ok <- expected_revision(current, expected_draft_revision),
             {:ok, next_revision} <- next_revision(current.draft_revision) do
          section = encode_section(next_revision, document)
          {:ok, section, external_draft(server.id, next_revision, document)}
        end
      end)
    end
  end

  @doc "Publishes the exact aggregate document at the expected draft revision."
  @spec publish(term(), term()) :: {:ok, ConfigVersions.config_version()} | {:error, Error.t()}
  def publish(server_id, expected_draft_revision) do
    with :ok <- validate_revision(expected_draft_revision),
         {:ok, draft} <- get(server_id),
         :ok <- expected_revision(draft, expected_draft_revision),
         {:ok, document} <- present_document(draft.document) do
      ConfigVersions.publish_exclusive(:server, draft.server_id, @operation, document)
    end
  end

  @doc "Republishes an earlier aggregate document as a new runtime version."
  @spec rollback(term(), term(), term()) ::
          {:ok, ConfigVersions.config_version()} | {:error, Error.t()}
  def rollback(server_id, version, expected_draft_revision) do
    with :ok <- validate_version(version),
         :ok <- validate_revision(expected_draft_revision),
         {:ok, draft} <- get(server_id),
         :ok <- expected_revision(draft, expected_draft_revision),
         {:ok, previous} <- ConfigVersions.get(:server, draft.server_id, version),
         :ok <- aggregate_version(previous),
         {:ok, document} <- validate_document(previous.payload) do
      ConfigVersions.publish_exclusive(:server, draft.server_id, @operation, document)
    end
  end

  defp read_manifest(path) do
    {deadline, config} = EventStore.operation()
    AtomicJson.owned(fn -> AtomicJson.read(path, config.file_ops) end, deadline)
  end

  defp registered_server(server_id) do
    case Servers.get(server_id) do
      {:ok, server} -> {:ok, server}
      {:error, :not_found} -> not_found("server not found")
      {:error, _reason} -> internal()
    end
  end

  defp decode_section(nil, server_id), do: {:ok, external_draft(server_id, 0, nil)}

  defp decode_section(section, server_id) when is_map(section) do
    with true <- Enum.sort(Map.keys(section)) == @section_keys,
         1 <- section["schema_version"],
         :ok <- validate_persisted_revision(section["draft_revision"]),
         {:ok, document} <- validate_document(section["document"]) do
      {:ok, external_draft(server_id, section["draft_revision"], document)}
    else
      _invalid -> invalid()
    end
  end

  defp decode_section(_section, _server_id), do: invalid()

  defp encode_section(draft_revision, document) do
    %{
      "schema_version" => 1,
      "draft_revision" => draft_revision,
      "document" => document
    }
  end

  defp external_draft(server_id, draft_revision, document) do
    %{server_id: server_id, draft_revision: draft_revision, document: document}
  end

  defp validate_document(document),
    do: Operation.validate_payload(@operation, :server, :config, document)

  defp validate_revision(revision)
       when is_integer(revision) and revision >= 0 and revision <= @max_revision,
       do: :ok

  defp validate_revision(_revision), do: invalid()

  defp validate_persisted_revision(revision)
       when is_integer(revision) and revision >= 1 and revision <= @max_revision,
       do: :ok

  defp validate_persisted_revision(_revision), do: invalid()

  defp validate_version(version)
       when is_integer(version) and version >= 1 and version <= @max_revision,
       do: :ok

  defp validate_version(_version), do: invalid()

  defp expected_revision(%{draft_revision: revision}, revision), do: :ok

  defp expected_revision(%{draft_revision: current}, expected) do
    {:error,
     Error.new(:conflict, "server config draft changed", %{
       "current_draft_revision" => current,
       "expected_draft_revision" => expected
     })}
  end

  defp next_revision(@max_revision),
    do: {:error, Error.new(:conflict, "server config draft revision limit reached", %{})}

  defp next_revision(revision), do: {:ok, revision + 1}

  defp present_document(document) when is_map(document), do: {:ok, document}
  defp present_document(nil), do: not_found("server config draft not found")

  defp aggregate_version(%{operation: @operation}), do: :ok
  defp aggregate_version(_version), do: invalid()

  defp invalid, do: {:error, Error.new(:invalid, "invalid server config draft", %{})}
  defp not_found(message), do: {:error, Error.new(:not_found, message, %{})}

  defp internal,
    do: {:error, Error.new(:internal, "server config draft persistence failed", %{})}
end
