defmodule YellowDog.Sync.Operation do
  @moduledoc false

  alias YellowDog.Sync.Bounds
  alias YellowDog.Sync.Codec
  alias YellowDog.Sync.Digest
  alias YellowDog.Sync.Error
  alias YellowDog.Sync.NetmanOperation
  alias YellowDog.Sync.ServerOperation

  @enforce_keys [
    :target_type,
    :kind,
    :capability,
    :payload_schema,
    :result_schema,
    :online?
  ]
  defstruct @enforce_keys

  @type kind :: :query | :command | :config
  @type t :: %__MODULE__{
          target_type: :server | :netman,
          kind: kind(),
          capability: String.t(),
          payload_schema: atom(),
          result_schema: atom(),
          online?: boolean()
        }

  @query_schemas [
    :dns_view_list_query,
    :dns_zone_list_query,
    :dns_record_list_query,
    :dns_acl_list_query,
    :dns_provider_list_query,
    :dns_log_list_query,
    :dns_metrics_query,
    :dhcp_pool_list_query,
    :dhcp_lease_list_query,
    :dhcp_activity_query,
    :dhcp_status_query,
    :mdns_service_list_query,
    :mdns_discovery_query,
    :mdns_monitor_query,
    :netboot_profile_list_query,
    :netboot_device_list_query,
    :netboot_asset_list_query,
    :netboot_transfer_list_query,
    :netboot_log_list_query,
    :identity_host_list_query,
    :identity_approval_list_query,
    :identity_token_list_query,
    :identity_audit_query,
    :settings_query,
    :profile_list_query,
    :network_links_query,
    :network_addresses_query,
    :network_routes_query,
    :network_connection_query
  ]

  @ref_schemas [
    :service_ref,
    :dns_view_ref,
    :dns_zone_ref,
    :dns_record_ref,
    :dns_acl_ref,
    :dns_provider_ref,
    :dhcp_pool_ref,
    :dhcp_force_delete,
    :dhcp_lease_ref,
    :mdns_service_ref,
    :netboot_profile_ref,
    :netboot_device_ref,
    :netboot_asset_ref,
    :netboot_asset_rescan,
    :identity_host_ref,
    :identity_token_ref,
    :settings_rollback,
    :profile_ref,
    :profile_rollback,
    :connection_ref,
    :dhcp_client_connection_ref,
    :resolved_config_rollback
  ]

  @write_schemas [
    :dns_view_write,
    :dns_zone_write,
    :dns_record_write,
    :dns_acl_write,
    :dns_provider_write,
    :dns_zone_sync,
    :dns_conflict_resolution,
    :dhcp_pool_write,
    :mdns_service_register,
    :mdns_service_update,
    :netboot_profile_write,
    :netboot_device_write,
    :identity_token_create,
    :identity_policy_set,
    :server_settings_config,
    :profile_validate,
    :profile_put,
    :profile_patch,
    :resolved_config_update
  ]

  @list_result_schemas [
    :service_list,
    :dns_view_list,
    :dns_zone_list,
    :dns_record_list,
    :dns_acl_list,
    :dns_provider_list,
    :dns_log_list,
    :dhcp_pool_list,
    :dhcp_lease_list,
    :dhcp_activity_list,
    :mdns_service_list,
    :mdns_discovery_list,
    :mdns_monitor_list,
    :netboot_profile_list,
    :netboot_device_list,
    :netboot_asset_list,
    :netboot_transfer_list,
    :netboot_log_list,
    :identity_host_list,
    :identity_approval_list,
    :identity_token_list,
    :identity_audit_list,
    :profile_list,
    :profile_history,
    :network_link_list,
    :network_address_list,
    :network_route_list,
    :resolved_upstream_list,
    :resolved_search_domain_list,
    :dhcp_client_lease_list
  ]

  @value_result_schemas [
    :runtime_capabilities,
    :runtime_health,
    :runtime_stats,
    :dns_metrics,
    :dhcp_status,
    :mdns_cache,
    :effective_settings,
    :settings_source,
    :settings_revision,
    :settings_validation,
    :apply_mode,
    :reconciliation_health,
    :profile_revision,
    :network_connection_state,
    :resolved_cache,
    :resolved_counters,
    :dhcp_client_fsm,
    :vpn_resolved_profile
  ]

  @command_result_schemas [
    :service_command_result,
    :revisioned_resource,
    :deleted_resource,
    :dns_import_result,
    :dns_sync_result,
    :lease_release_result,
    :cache_clear_result,
    :netboot_asset,
    :netboot_asset_rescan_result,
    :identity_token_create_result,
    :profile_validation,
    :profile_activation_result,
    :connection_activation_result
  ]

  @spec lookup(term()) :: {:ok, t()} | {:error, Error.t()}
  def lookup("server." <> _rest = name), do: ServerOperation.fetch(name)
  def lookup("netman." <> _rest = name), do: NetmanOperation.fetch(name)
  def lookup(_name), do: invalid_error()

  @spec validate_payload(t(), term()) :: {:ok, term()} | {:error, Error.t()}
  def validate_payload(%__MODULE__{payload_schema: schema}, payload),
    do: validate_schema(schema, payload)

  def validate_payload(_operation, _payload), do: invalid_error()

  @spec validate_payload(term(), term(), term(), term()) ::
          {:ok, term()} | {:error, Error.t()}
  def validate_payload(name, target_type, kind, payload) do
    with {:ok, %__MODULE__{target_type: ^target_type, kind: ^kind} = operation} <- lookup(name) do
      validate_payload(operation, payload)
    else
      _ -> invalid_error()
    end
  end

  @spec validate_result(t(), term()) :: {:ok, term()} | {:error, Error.t()}
  def validate_result(%__MODULE__{result_schema: schema}, result),
    do: validate_schema(schema, result)

  def validate_result(_operation, _result), do: invalid_error()

  @spec validate_result(term(), term(), term(), term()) ::
          {:ok, term()} | {:error, Error.t()}
  def validate_result(name, target_type, kind, result) do
    with {:ok, %__MODULE__{target_type: ^target_type, kind: ^kind} = operation} <- lookup(name) do
      validate_result(operation, result)
    else
      _ -> invalid_error()
    end
  end

  @spec validate_envelope(YellowDog.Sync.Envelope.t(), kind()) ::
          {:ok, YellowDog.Sync.Envelope.t()} | {:error, Error.t()}
  def validate_envelope(%YellowDog.Sync.Envelope{} = envelope, kind) do
    with {:ok, _encoded} <- YellowDog.Sync.Envelope.encode(envelope),
         {:ok, _payload} <-
           validate_payload(envelope.operation, envelope.target_type, kind, envelope.payload) do
      {:ok, envelope}
    end
  end

  def validate_envelope(_envelope, _kind), do: invalid_error()

  defp validate_schema(:empty, value), do: exact_map(value, [])

  defp validate_schema(schema, value) when schema in @query_schemas do
    with {:ok, value} <- allowed_map(value, ["scope", "filter", "cursor", "limit"]),
         :ok <- optional_text(value, "scope"),
         :ok <- optional_text(value, "filter"),
         :ok <- optional_text(value, "cursor"),
         :ok <- optional_limit(value, "limit") do
      {:ok, value}
    else
      _ -> invalid_error()
    end
  end

  defp validate_schema(schema, value) when schema in @ref_schemas do
    with {:ok, value} <- exact_map(value, ["resource_id"]),
         {:ok, _resource_id} <- valid_id(value["resource_id"]) do
      {:ok, value}
    else
      _ -> invalid_error()
    end
  end

  defp validate_schema(:mdns_service_toggle, value) do
    with {:ok, value} <- exact_map(value, ["resource_id", "enabled"]),
         {:ok, _resource_id} <- valid_id(value["resource_id"]),
         true <- is_boolean(value["enabled"]) do
      {:ok, value}
    else
      _ -> invalid_error()
    end
  end

  defp validate_schema(schema, value) when schema in @write_schemas do
    with {:ok, value} <- exact_map(value, ["resource_id", "value"]),
         {:ok, _resource_id} <- valid_id(value["resource_id"]),
         {:ok, _value} <- bounded_map(value["value"]) do
      {:ok, value}
    else
      _ -> invalid_error()
    end
  end

  defp validate_schema(schema, value) when schema in [:dns_zone_import, :netboot_asset_upload] do
    with {:ok, value} <-
           exact_map(value, ["resource_id", "filename", "size", "blob_digest"]),
         {:ok, _resource_id} <- valid_id(value["resource_id"]),
         {:ok, _filename} <- nonempty_text(value["filename"]),
         true <- is_integer(value["size"]) and value["size"] >= 0,
         {:ok, _digest} <- Digest.validate(value["blob_digest"]) do
      {:ok, value}
    else
      _ -> invalid_error()
    end
  end

  defp validate_schema(schema, value) when schema in @list_result_schemas do
    with {:ok, value} <- exact_map(value, ["items", "revision", "observed_at"]),
         {:ok, items} <- Bounds.list(value["items"]),
         :ok <- validate_items(items),
         {:ok, _revision} <- Digest.validate(value["revision"]),
         {:ok, _observed_at} <- utc_datetime(value["observed_at"]) do
      {:ok, value}
    else
      _ -> invalid_error()
    end
  end

  defp validate_schema(schema, value) when schema in @value_result_schemas do
    with {:ok, value} <- exact_map(value, ["value", "revision", "observed_at"]),
         {:ok, _nested_value} <- bounded_map(value["value"]),
         {:ok, _revision} <- Digest.validate(value["revision"]),
         {:ok, _observed_at} <- utc_datetime(value["observed_at"]) do
      {:ok, value}
    else
      _ -> invalid_error()
    end
  end

  defp validate_schema(schema, value) when schema in @command_result_schemas do
    with {:ok, value} <- exact_map(value, ["resource_id", "revision", "value"]),
         {:ok, _resource_id} <- valid_id(value["resource_id"]),
         {:ok, _revision} <- Digest.validate(value["revision"]),
         {:ok, _nested_value} <- bounded_map(value["value"]) do
      {:ok, value}
    else
      _ -> invalid_error()
    end
  end

  defp validate_schema(:config_state, value) do
    keys = [
      "state",
      "version",
      "digest",
      "applied_revision",
      "previous_revision",
      "failure",
      "rollback"
    ]

    with {:ok, value} <- exact_map(value, keys),
         true <- value["state"] in ["desired", "delivered", "applying", "applied", "failed"],
         {:ok, _version} <- valid_id(value["version"]),
         {:ok, _digest} <- Digest.validate(value["digest"]),
         :ok <- optional_digest(value["applied_revision"]),
         :ok <- optional_digest(value["previous_revision"]),
         :ok <- optional_details(value["failure"]),
         :ok <- optional_details(value["rollback"]) do
      {:ok, value}
    else
      _ -> invalid_error()
    end
  end

  defp validate_schema(_schema, _value), do: invalid_error()

  defp exact_map(value, keys) when is_map(value) do
    if Map.keys(value) |> Enum.sort() == Enum.sort(keys), do: {:ok, value}, else: invalid_error()
  end

  defp exact_map(_value, _keys), do: invalid_error()

  defp allowed_map(value, keys) when is_map(value) do
    if Enum.all?(Map.keys(value), &(&1 in keys)), do: {:ok, value}, else: invalid_error()
  end

  defp allowed_map(_value, _keys), do: invalid_error()

  defp valid_id(value) do
    with {:ok, value} <- Bounds.id(value),
         true <- value != "" do
      {:ok, value}
    else
      _ -> invalid_error()
    end
  end

  defp nonempty_text(value) do
    with {:ok, value} <- Bounds.message(value),
         true <- value != "" do
      {:ok, value}
    else
      _ -> invalid_error()
    end
  end

  defp optional_text(value, key) do
    case Map.fetch(value, key) do
      :error -> :ok
      {:ok, text} -> normalize_validation(Bounds.message(text))
    end
  end

  defp optional_limit(value, key) do
    case Map.fetch(value, key) do
      :error ->
        :ok

      {:ok, limit} when is_integer(limit) and limit > 0 ->
        if limit <= Bounds.max_list_entries(), do: :ok, else: invalid_error()

      _ ->
        invalid_error()
    end
  end

  defp bounded_map(value) when is_map(value) do
    with {:ok, _value} <- Bounds.map(value),
         {:ok, encoded} <- Codec.encode(value),
         {:ok, _encoded} <- Bounds.payload(encoded) do
      {:ok, value}
    else
      _ -> invalid_error()
    end
  end

  defp bounded_map(_value), do: invalid_error()

  defp validate_items(items) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case bounded_map(item) do
        {:ok, _item} -> {:cont, :ok}
        _ -> {:halt, invalid_error()}
      end
    end)
  end

  defp utc_datetime(value) when is_binary(value) do
    with {:ok, datetime, 0} <- DateTime.from_iso8601(value),
         true <- String.ends_with?(value, "Z") do
      {:ok, datetime}
    else
      _ -> invalid_error()
    end
  end

  defp utc_datetime(_value), do: invalid_error()

  defp optional_digest(nil), do: :ok
  defp optional_digest(value), do: normalize_validation(Digest.validate(value))

  defp optional_details(nil), do: :ok
  defp optional_details(value), do: normalize_validation(Bounds.details(value))

  defp normalize_validation({:ok, _value}), do: :ok
  defp normalize_validation(_error), do: invalid_error()

  defp invalid_error, do: {:error, Error.new(:invalid, "invalid value", %{})}
end
