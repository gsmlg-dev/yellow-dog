defmodule YellowDog.Management.Netmans do
  @moduledoc "PostgreSQL-owned logical Netman metadata and desired configuration history."

  import Ecto.Query

  alias YellowDog.Management.{
    Netman,
    NetmanConfig,
    NetmanConfigDraft,
    NetmanConfigVersion,
    ProfileCatalog,
    Repo
  }

  @identifier ~r/^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/
  def list do
    Repo.all(from(node in Netman, order_by: node.id)) |> Enum.map(&node_map/1)
  end

  def get(id) do
    if valid_identifier?(id) do
      case Repo.get(Netman, id) do
        nil -> {:error, failure("not_found", "Netman not found")}
        node -> {:ok, node_map(node)}
      end
    else
      {:error, failure("invalid_request", "Invalid Netman ID")}
    end
  end

  def get_config(id) do
    if valid_identifier?(id) do
      case Repo.get(NetmanConfigDraft, id) do
        nil -> {:error, failure("not_found", "Netman configuration not found")}
        draft -> {:ok, draft_map(draft)}
      end
    else
      {:error, failure("invalid_request", "Invalid Netman ID")}
    end
  end

  def versions(id) do
    if valid_identifier?(id) do
      Repo.all(
        from(version in NetmanConfigVersion,
          where: version.netman_id == ^id,
          order_by: [desc: version.version]
        )
      )
      |> Enum.map(&version_map/1)
    else
      []
    end
  end

  def history do
    Repo.all(
      from(version in NetmanConfigVersion,
        join: node in Netman,
        on: node.id == version.netman_id,
        order_by: [desc: version.inserted_at, asc: version.netman_id],
        select: {version, node.name}
      )
    )
    |> Enum.map(fn {version, name} -> Map.put(version_map(version), "netman_name", name) end)
  end

  def dispatch("create_netman", params) do
    allowed_keys!(params, ~w(id name profile_name apply_mode features metadata))
    id = identifier!(params)
    if Repo.get(Netman, id), do: abort("conflict", "Netman ID already exists")
    preset = preset!(Map.get(params, "profile_name", "custom"))

    node =
      Repo.insert!(%Netman{
        id: id,
        name: text!(Map.get(params, "name", id), "name", 128),
        profile_name: to_string(preset.name),
        apply_mode: mode!(Map.get(params, "apply_mode", to_string(preset.apply_mode))),
        features: features!(Map.get(params, "features", string_features(preset.features))),
        metadata: metadata!(Map.get(params, "metadata", %{}))
      })

    Repo.insert!(%NetmanConfigDraft{netman_id: id, document: NetmanConfig.default()})
    node_map(node)
  end

  def dispatch("update_netman", params) do
    allowed_keys!(params, ~w(id name profile_name apply_mode features metadata expected_revision))
    node = lock_node!(identifier!(params))
    expect_revision!(node.revision, params)
    preset = preset!(Map.get(params, "profile_name", node.profile_name))
    changed_preset = to_string(preset.name) != node.profile_name
    default_mode = if changed_preset, do: to_string(preset.apply_mode), else: node.apply_mode

    default_features =
      if changed_preset, do: string_features(preset.features), else: node.features

    node
    |> Ecto.Changeset.change(
      name: text!(Map.get(params, "name", node.name), "name", 128),
      profile_name: to_string(preset.name),
      apply_mode: mode!(Map.get(params, "apply_mode", default_mode)),
      features: features!(Map.get(params, "features", default_features)),
      metadata: metadata!(Map.get(params, "metadata", node.metadata)),
      revision: node.revision + 1
    )
    |> Repo.update!()
    |> node_map()
  end

  def dispatch("update_netman_config", params) do
    allowed_keys!(params, ~w(id expected_revision document))
    node = lock_node!(identifier!(params))
    mutable!(node)
    draft = lock_draft!(node.id)
    expect_revision!(draft.revision, params)
    document = validated_document!(Map.get(params, "document"))

    if document == draft.document do
      draft_map(draft)
    else
      draft
      |> Ecto.Changeset.change(document: document, revision: draft.revision + 1)
      |> Repo.update!()
      |> draft_map()
    end
  end

  def dispatch("confirm_netman_config", params) do
    allowed_keys!(params, ~w(id expected_revision))
    node = lock_node!(identifier!(params))
    mutable!(node)
    draft = lock_draft!(node.id)
    expect_revision!(draft.revision, params)

    existing =
      Repo.one(
        from(version in NetmanConfigVersion,
          where: version.netman_id == ^node.id and version.source_revision == ^draft.revision
        )
      )

    version_map(existing || publish!(draft, "confirm_netman_config", nil))
  end

  def dispatch("rollback_netman_config", params) do
    allowed_keys!(params, ~w(id expected_revision target_version))
    node = lock_node!(identifier!(params))
    mutable!(node)
    draft = lock_draft!(node.id)
    expect_revision!(draft.revision, params)
    target_version = Map.get(params, "target_version")

    unless is_integer(target_version) and target_version > 0,
      do: abort("invalid_request", "target_version must be a positive integer")

    target =
      Repo.one(
        from(version in NetmanConfigVersion,
          where: version.netman_id == ^node.id and version.version == ^target_version
        )
      )

    if is_nil(target), do: abort("not_found", "Netman configuration version not found")
    document = validated_document!(target.document)

    next_draft =
      draft
      |> Ecto.Changeset.change(document: document, revision: draft.revision + 1)
      |> Repo.update!()

    publish!(next_draft, "rollback_netman_config", target.id) |> version_map()
  end

  defp publish!(draft, operation, rollback_source_id) do
    latest =
      Repo.one(
        from(version in NetmanConfigVersion,
          where: version.netman_id == ^draft.netman_id,
          select: max(version.version)
        )
      ) || 0

    Repo.insert!(%NetmanConfigVersion{
      netman_id: draft.netman_id,
      version: latest + 1,
      source_revision: draft.revision,
      operation: operation,
      document: draft.document,
      digest: document_digest(draft.document),
      rollback_source_id: rollback_source_id
    })
  end

  defp lock_node!(id) do
    Repo.one(from(node in Netman, where: node.id == ^id, lock: "FOR UPDATE")) ||
      abort("not_found", "Netman not found")
  end

  defp lock_draft!(id) do
    Repo.one!(from(draft in NetmanConfigDraft, where: draft.netman_id == ^id, lock: "FOR UPDATE"))
  end

  defp mutable!(%Netman{apply_mode: "observe"}),
    do: abort("read_only", "Observe-only Netman configuration cannot be changed or published")

  defp mutable!(_node), do: :ok

  defp expect_revision!(revision, params) do
    unless is_integer(params["expected_revision"]) and params["expected_revision"] > 0,
      do: abort("invalid_request", "expected_revision must be a positive integer")

    if params["expected_revision"] !== revision,
      do:
        abort("revision_conflict", "Expected revision does not match current revision", %{
          "actual" => revision,
          "expected" => params["expected_revision"]
        })
  end

  defp validated_document!(document) do
    case NetmanConfig.validate(document) do
      {:ok, normalized} -> normalized
      {:error, error} -> throw({:management_abort, error})
    end
  end

  defp identifier!(params) do
    id = text!(Map.get(params, "id"), "id", 64)

    unless valid_identifier?(id),
      do:
        abort("invalid_request", "Netman ID must use letters, digits, dot, underscore, or hyphen")

    id
  end

  defp valid_identifier?(id),
    do: is_binary(id) and String.valid?(id) and Regex.match?(@identifier, id)

  defp text!(value, field, maximum) do
    unless is_binary(value) and String.valid?(value) and byte_size(value) in 1..maximum and
             String.trim(value) == value and not String.contains?(value, <<0>>),
           do: abort("invalid_request", "#{field} must be a bounded nonempty string")

    value
  end

  defp preset!(name) do
    Enum.find(ProfileCatalog.list_netman_profiles(), &(to_string(&1.name) == name)) ||
      abort("invalid_request", "Unknown Netman profile")
  end

  defp mode!(mode) do
    if mode in ~w(managed observe_first observe),
      do: mode,
      else: abort("invalid_request", "Unknown Netman apply mode")
  end

  defp features!(features) do
    keys = Enum.map(ProfileCatalog.netman_feature_keys(), &to_string/1)

    unless is_map(features) and
             Enum.all?(features, fn {key, value} -> key in keys and is_boolean(value) end),
           do:
             abort(
               "invalid_request",
               "Netman features must contain only known Boolean feature flags"
             )

    Map.merge(Map.new(keys, &{&1, false}), features)
  end

  defp metadata!(metadata) do
    unless is_map(metadata) and byte_size(Jason.encode!(metadata)) <= 16_384,
      do: abort("invalid_request", "Netman metadata must be an object of at most 16 KiB")

    metadata
  end

  defp string_features(features),
    do: Map.new(features, fn {key, value} -> {to_string(key), value} end)

  defp allowed_keys!(params, keys) do
    case Enum.find(Map.keys(params), &(&1 not in keys)) do
      nil -> :ok
      field -> abort("invalid_request", "Unsupported field: #{field}")
    end
  end

  defp node_map(node) do
    %{
      "id" => node.id,
      "name" => node.name,
      "profile_name" => node.profile_name,
      "apply_mode" => node.apply_mode,
      "features" => node.features,
      "metadata" => node.metadata,
      "status" => node.status,
      "actual_state" => "unknown",
      "last_seen_at" => nil,
      "revision" => node.revision,
      "registered_at" => DateTime.to_iso8601(node.inserted_at),
      "updated_at" => DateTime.to_iso8601(node.updated_at)
    }
  end

  defp draft_map(draft),
    do: %{
      "netman_id" => draft.netman_id,
      "revision" => draft.revision,
      "document" => draft.document,
      "actual_state" => "unknown"
    }

  defp version_map(version) do
    %{
      "id" => version.id,
      "netman_id" => version.netman_id,
      "version" => version.version,
      "source_revision" => version.source_revision,
      "operation" => version.operation,
      "document" => version.document,
      "digest" => version.digest,
      "rollback_source_id" => version.rollback_source_id,
      "inserted_at" => DateTime.to_iso8601(version.inserted_at),
      "status" => "prepared",
      "actual_state" => "unknown"
    }
  end

  defp document_digest(document),
    do:
      :crypto.hash(:sha256, :erlang.term_to_binary(canonical(document)))
      |> Base.encode16(case: :lower)

  defp canonical(document) when is_map(document),
    do: document |> Enum.sort() |> Enum.map(fn {key, value} -> {key, canonical(value)} end)

  defp canonical(values) when is_list(values), do: Enum.map(values, &canonical/1)
  defp canonical(value), do: value

  defp abort(code, message, details \\ %{}),
    do: throw({:management_abort, failure(code, message, details)})

  defp failure(code, message, details \\ %{}),
    do: %{code: code, message: message, details: details}
end
