defmodule YellowDog.Sync.Operation do
  @moduledoc false

  import Bitwise

  alias YellowDog.Sync.Bounds
  alias YellowDog.Sync.Digest
  alias YellowDog.Sync.Envelope
  alias YellowDog.Sync.Error
  alias YellowDog.Sync.NetmanOperation
  alias YellowDog.Sync.ServerOperation

  @enforce_keys [
    :name,
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
          name: String.t(),
          target_type: :server | :netman,
          kind: kind(),
          capability: String.t(),
          payload_schema: atom(),
          result_schema: atom(),
          online?: boolean()
        }

  @max_schema_depth 8
  @max_collection_size 100
  @max_integer 9_223_372_036_854_775_807

  @forbidden_keys MapSet.new([
                    "expectedrevision",
                    "path",
                    "localpath",
                    "filepath",
                    "pathname",
                    "file",
                    "pid",
                    "processid",
                    "ref",
                    "reference",
                    "port",
                    "ets",
                    "etstable",
                    "table",
                    "tableid",
                    "kernelhandle",
                    "kernelmanagerhandle",
                    "managerhandle",
                    "handle",
                    "blob",
                    "blobbytes",
                    "blobcontent",
                    "blobdata",
                    "content",
                    "bytes",
                    "data"
                  ])
  @forbidden_setting_tokens MapSet.new(~w(
                                path file pid port ets table kernel manager handle
                              ))
  @forbidden_setting_phrases ~w(
                               expectedrevision localpath filepath pathname etstable kernelhandle
                               kernelmanagerhandle managerhandle
                             )
  @material_tokens MapSet.new(
                     ~w(raw payload body content blob byte cert certificate pem pkcs12 pfx)
                   )
  @material_plural_tokens %{
    "payloads" => "payload",
    "bodies" => "body",
    "contents" => "content",
    "blobs" => "blob",
    "bytes" => "byte",
    "certs" => "cert",
    "certificates" => "certificate",
    "keys" => "key",
    "pems" => "pem",
    "pfxs" => "pfx"
  }
  @private_key_prefixes MapSet.new(~w(private tls secret signing))
  @separatorless_material_roots ~w(raw payload body bodies content blob byte bytes cert certificate pem pkcs12 pfx)
  @material_reference_suffixes ~w(digest hash uri url ref id)
  @glued_reference_suffixes ~w(reference digest hash uri url ref id)
  @canonical_setting_key ~r/\A[a-z][a-z0-9]*(?:_[a-z0-9]+)*\z/

  @spec lookup(term()) :: {:ok, t()} | {:error, Error.t()}
  def lookup("server." <> _rest = name), do: ServerOperation.fetch(name)
  def lookup("netman." <> _rest = name), do: NetmanOperation.fetch(name)
  def lookup(_name), do: invalid_error()

  @spec validate_schema(atom(), term()) :: {:ok, term()} | {:error, Error.t()}
  def validate_schema(schema, value) when is_atom(schema) do
    with spec when not is_nil(spec) <- schema_spec(schema),
         :ok <- validate_transport(value),
         :ok <- validate_type(value, spec, @max_schema_depth) do
      {:ok, value}
    else
      _ -> invalid_error()
    end
  end

  def validate_schema(_schema, _value), do: invalid_error()

  @spec validate_transport(term()) :: :ok | {:error, Error.t()}
  def validate_transport(value), do: transport_safe(value, @max_schema_depth)

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
  def validate_result(%__MODULE__{} = operation, result) do
    with {:ok, result} <- validate_schema(operation.result_schema, result),
         :ok <- validate_result_domain(operation, result) do
      {:ok, result}
    else
      _ -> invalid_error()
    end
  end

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

  @spec validate_envelope(Envelope.t(), kind()) ::
          {:ok, Envelope.t()} | {:error, Error.t()}
  def validate_envelope(%Envelope{} = envelope, kind) do
    with {:ok, _encoded} <- Envelope.encode(envelope),
         :ok <- validate_config_version(envelope.config_version, kind),
         {:ok, _payload} <-
           validate_payload(envelope.operation, envelope.target_type, kind, envelope.payload) do
      {:ok, envelope}
    end
  end

  def validate_envelope(_envelope, _kind), do: invalid_error()

  defp schema_spec(:empty), do: object(%{})

  defp schema_spec(:dns_view_list_query), do: query(%{})
  defp schema_spec(:dns_zone_list_query), do: query(%{"view_name" => :id})

  defp schema_spec(:dns_record_list_query),
    do: query(%{"view_name" => :id, "zone_name" => :domain})

  defp schema_spec(:dns_acl_list_query), do: query(%{})
  defp schema_spec(:dns_provider_list_query), do: query(%{})
  defp schema_spec(:dns_log_list_query), do: query(%{"view_name" => :id})
  defp schema_spec(:dns_metrics_query), do: query(%{})
  defp schema_spec(:dhcp_pool_list_query), do: family_query()
  defp schema_spec(:dhcp_lease_list_query), do: family_query()
  defp schema_spec(:dhcp_activity_query), do: family_query()
  defp schema_spec(:dhcp_status_query), do: family_query()
  defp schema_spec(:mdns_service_list_query), do: query(%{})
  defp schema_spec(:mdns_discovery_query), do: query(%{})
  defp schema_spec(:mdns_monitor_query), do: query(%{})
  defp schema_spec(:netboot_profile_list_query), do: query(%{})
  defp schema_spec(:netboot_device_list_query), do: query(%{})
  defp schema_spec(:netboot_asset_list_query), do: query(%{})
  defp schema_spec(:netboot_transfer_list_query), do: query(%{})
  defp schema_spec(:netboot_log_list_query), do: query(%{})
  defp schema_spec(:identity_host_list_query), do: query(%{})
  defp schema_spec(:identity_approval_list_query), do: query(%{})
  defp schema_spec(:identity_token_list_query), do: query(%{})
  defp schema_spec(:identity_audit_query), do: query(%{})
  defp schema_spec(:settings_query), do: query(%{"service" => :id})
  defp schema_spec(:profile_list_query), do: query(%{})
  defp schema_spec(:network_links_query), do: query(%{})
  defp schema_spec(:network_addresses_query), do: query(%{})
  defp schema_spec(:network_routes_query), do: query(%{})
  defp schema_spec(:network_connection_query), do: query(%{"connection_id" => :id})

  defp schema_spec(:service_ref), do: object(%{"service" => :id})
  defp schema_spec(:dns_view_ref), do: object(%{"view_name" => :id})

  defp schema_spec(:dns_zone_ref),
    do: object(%{"view_name" => :id, "zone_name" => :domain})

  defp schema_spec(:dns_record_ref), do: dns_record_ref()
  defp schema_spec(:dns_acl_ref), do: object(%{"acl_id" => :id})
  defp schema_spec(:dns_provider_ref), do: object(%{"provider_id" => :id})
  defp schema_spec(:dhcp_pool_ref), do: family_ref("pool_id")

  defp schema_spec(:dhcp_force_delete),
    do: object(%{"family" => family(), "pool_id" => :id, "force" => {:literal, true}})

  defp schema_spec(:dhcp_lease_ref), do: family_ref("lease_id")
  defp schema_spec(:mdns_service_ref), do: object(%{"service_id" => :id})
  defp schema_spec(:netboot_profile_ref), do: object(%{"profile_id" => :id})
  defp schema_spec(:netboot_device_ref), do: object(%{"device_id" => :id})
  defp schema_spec(:netboot_asset_ref), do: object(%{"asset_id" => :id})
  defp schema_spec(:netboot_asset_rescan), do: object(%{"scope" => enum(["all", "missing"])})
  defp schema_spec(:identity_host_ref), do: object(%{"host_id" => :id})
  defp schema_spec(:identity_token_ref), do: object(%{"token_id" => :id})

  defp schema_spec(:settings_rollback),
    do: object(%{"service" => :id, "target_revision" => :digest})

  defp schema_spec(:profile_ref), do: object(%{"profile_id" => :id})

  defp schema_spec(:profile_rollback),
    do: object(%{"profile_id" => :id, "target_revision" => :digest})

  defp schema_spec(:connection_ref), do: object(%{"connection_id" => :id})
  defp schema_spec(:dhcp_client_connection_ref), do: object(%{"connection_id" => :id})
  defp schema_spec(:resolved_config_rollback), do: object(%{"target_revision" => :digest})

  defp schema_spec(:dns_view_write), do: dns_view()
  defp schema_spec(:dns_zone_write), do: dns_zone()
  defp schema_spec(:dns_record_write), do: dns_record()
  defp schema_spec(:dns_acl_write), do: dns_acl()
  defp schema_spec(:dns_provider_write), do: dns_provider()

  defp schema_spec(:dns_zone_import), do: :dns_zone_import

  defp schema_spec(:dns_zone_sync),
    do: object(%{"view_name" => :id, "zone_name" => :domain, "provider_id" => :id})

  defp schema_spec(:dns_conflict_resolution),
    do: object(%{"conflict_id" => :id, "resolution" => enum(["use_local", "use_cloud"])})

  defp schema_spec(:dhcp_pool_write), do: dhcp_pool()
  defp schema_spec(:mdns_service_register), do: mdns_service()
  defp schema_spec(:mdns_service_update), do: mdns_service()

  defp schema_spec(:mdns_service_toggle),
    do: object(%{"service_id" => :id, "enabled" => :boolean})

  defp schema_spec(:netboot_profile_write), do: netboot_profile()
  defp schema_spec(:netboot_device_write), do: netboot_device()

  defp schema_spec(:netboot_asset_upload) do
    object(%{
      "asset_id" => :id,
      "filename" => :normalized_relative_filename,
      "size" => nonnegative_integer(),
      "blob_digest" => :digest
    })
  end

  defp schema_spec(:identity_token_create),
    do:
      object(%{
        "token_id" => :id,
        "label" => :nonempty_text,
        "expires_at" => nullable(:utc_datetime)
      })

  defp schema_spec(:identity_policy_set),
    do: object(%{"policies" => list(identity_policy())})

  defp schema_spec(:server_settings_config), do: settings_document()
  defp schema_spec(:profile_validate), do: netman_profile()
  defp schema_spec(:profile_put), do: netman_profile()

  defp schema_spec(:profile_patch),
    do:
      object(%{
        "profile_id" => :id,
        "changes" => list(:profile_change)
      })

  defp schema_spec(:resolved_config_update),
    do: object(%{"upstreams" => list(:ip), "search_domains" => list(:domain)})

  defp schema_spec(:service_list), do: list_result(service_item())
  defp schema_spec(:dns_view_list), do: list_result(dns_view())
  defp schema_spec(:dns_zone_list), do: list_result(dns_zone())
  defp schema_spec(:dns_record_list), do: list_result(dns_record())
  defp schema_spec(:dns_acl_list), do: list_result(dns_acl())
  defp schema_spec(:dns_provider_list), do: list_result(dns_provider())
  defp schema_spec(:dns_log_list), do: list_result(dns_log_item())
  defp schema_spec(:dhcp_pool_list), do: list_result(dhcp_pool())
  defp schema_spec(:dhcp_lease_list), do: list_result(dhcp_lease_item())
  defp schema_spec(:dhcp_activity_list), do: list_result(dhcp_activity_item())
  defp schema_spec(:mdns_service_list), do: list_result(mdns_service())
  defp schema_spec(:mdns_discovery_list), do: list_result(mdns_discovery_item())
  defp schema_spec(:mdns_monitor_list), do: list_result(mdns_monitor_item())
  defp schema_spec(:netboot_profile_list), do: list_result(netboot_profile())
  defp schema_spec(:netboot_device_list), do: list_result(netboot_device())
  defp schema_spec(:netboot_asset_list), do: list_result(netboot_asset())
  defp schema_spec(:netboot_transfer_list), do: list_result(netboot_transfer_item())
  defp schema_spec(:netboot_log_list), do: list_result(netboot_log_item())
  defp schema_spec(:identity_host_list), do: list_result(identity_host_item())
  defp schema_spec(:identity_approval_list), do: list_result(identity_approval_item())
  defp schema_spec(:identity_token_list), do: list_result(identity_token_item())
  defp schema_spec(:identity_audit_list), do: list_result(identity_audit_item())
  defp schema_spec(:profile_list), do: list_result(netman_profile())
  defp schema_spec(:profile_history), do: list_result(profile_history_item())
  defp schema_spec(:network_link_list), do: list_result(network_link_item())
  defp schema_spec(:network_address_list), do: list_result(network_address_item())
  defp schema_spec(:network_route_list), do: list_result(network_route_item())
  defp schema_spec(:resolved_upstream_list), do: list_result(resolved_upstream_item())

  defp schema_spec(:resolved_search_domain_list),
    do: list_result(resolved_search_domain_item())

  defp schema_spec(:dhcp_client_lease_list), do: list_result(dhcp_client_lease_item())

  defp schema_spec(:runtime_capabilities),
    do: object(%{"capabilities" => list(:nonempty_text)})

  defp schema_spec(:runtime_health),
    do: object(%{"status" => health(), "checks" => list(health_check())})

  defp schema_spec(:runtime_stats),
    do: object(%{"requests" => nonnegative_integer(), "errors" => nonnegative_integer()})

  defp schema_spec(:dns_metrics),
    do: object(%{"queries" => nonnegative_integer(), "failures" => nonnegative_integer()})

  defp schema_spec(:dhcp_status),
    do: object(%{"family" => family(), "status" => service_state()})

  defp schema_spec(:mdns_cache),
    do: object(%{"entries" => list(mdns_cache_item())})

  defp schema_spec(:effective_settings), do: settings_document()

  defp schema_spec(:settings_source),
    do: object(%{"service" => :id, "source" => enum(["managed", "local", "default"])})

  defp schema_spec(:settings_revision),
    do: object(%{"service" => :id, "revision" => :digest})

  defp schema_spec(:settings_validation),
    do: object(%{"service" => :id, "valid" => :boolean, "errors" => list(validation_error())})

  defp schema_spec(:apply_mode),
    do: object(%{"mode" => enum(["managed", "standalone", "observe_first", "observe"])})

  defp schema_spec(:reconciliation_health),
    do: object(%{"status" => health(), "pending_changes" => nonnegative_integer()})

  defp schema_spec(:profile_revision),
    do: object(%{"profile_id" => :id, "revision" => :digest})

  defp schema_spec(:network_connection_state),
    do: object(%{"connection_id" => :id, "state" => connection_state()})

  defp schema_spec(:resolved_cache),
    do: object(%{"entries" => list(resolved_cache_item())})

  defp schema_spec(:resolved_counters),
    do: object(%{"hits" => nonnegative_integer(), "misses" => nonnegative_integer()})

  defp schema_spec(:dhcp_client_fsm),
    do:
      object(%{
        "connection_id" => :id,
        "state" => enum(["init", "selecting", "requesting", "bound", "renewing", "rebinding"])
      })

  defp schema_spec(:vpn_resolved_profile),
    do: object(%{"profile_id" => :id, "state" => enum(["resolved", "unavailable"])})

  defp schema_spec(:service_command_result),
    do: object(%{"service" => :id, "state" => service_state()})

  defp schema_spec(:revisioned_resource), do: :revisioned_resource
  defp schema_spec(:deleted_resource), do: :deleted_resource

  defp schema_spec(:dns_import_result),
    do:
      object(%{
        "view_name" => :id,
        "zone_name" => :domain,
        "imported_records" => nonnegative_integer(),
        "revision" => :digest
      })

  defp schema_spec(:dns_sync_result),
    do:
      object(%{
        "view_name" => :id,
        "zone_name" => :domain,
        "changed_records" => nonnegative_integer(),
        "revision" => :digest
      })

  defp schema_spec(:lease_release_result), do: :lease_release_result

  defp schema_spec(:cache_clear_result),
    do: object(%{"cleared_entries" => nonnegative_integer()})

  defp schema_spec(:netboot_asset), do: netboot_asset()

  defp schema_spec(:netboot_asset_rescan_result),
    do:
      object(%{"scope" => enum(["all", "missing"]), "discovered_assets" => nonnegative_integer()})

  defp schema_spec(:identity_token_create_result),
    do:
      object(%{
        "token_id" => :id,
        "secret" => :nonempty_text,
        "expires_at" => nullable(:utc_datetime)
      })

  defp schema_spec(:profile_validation),
    do: object(%{"profile_id" => :id, "valid" => :boolean, "errors" => list(validation_error())})

  defp schema_spec(:profile_activation_result),
    do: object(%{"profile_id" => :id, "revision" => :digest, "state" => connection_state()})

  defp schema_spec(:connection_activation_result),
    do: object(%{"connection_id" => :id, "state" => connection_state()})

  defp schema_spec(:config_state), do: :config_state
  defp schema_spec(_schema), do: nil

  defp config_state_shape do
    object(%{
      "state" => enum(["delivered", "applying", "applied", "failed"]),
      "version" => positive_integer(),
      "digest" => :digest,
      "applied_revision" => nullable(:digest),
      "previous_version" => nullable(positive_integer()),
      "previous_revision" => nullable(:digest),
      "failure" => nullable(config_failure()),
      "rollback" => nullable(rollback_result())
    })
  end

  defp query(required) do
    object(required, %{
      "cursor" => :id,
      "limit" => {:integer, 1, @max_collection_size}
    })
  end

  defp family_query, do: query(%{"family" => family()})
  defp family_ref(id_key), do: object(%{"family" => family(), id_key => :id})

  defp list_result(item) do
    object(%{
      "items" => list(item, Bounds.max_list_entries()),
      "revision" => :digest,
      "observed_at" => :utc_datetime
    })
  end

  defp dns_record_ref do
    object(%{"view_name" => :id, "zone_name" => :domain, "record_id" => :id})
  end

  defp dns_view do
    object(%{
      "view_name" => :id,
      "match_clients" => list(:cidr),
      "recursion" => :boolean
    })
  end

  defp dns_zone do
    object(%{
      "view_name" => :id,
      "zone_name" => :domain,
      "zone_type" => enum(["authoritative", "forward"]),
      "provider_id" => nullable(:id)
    })
  end

  defp dns_record, do: :dns_record

  defp dns_record_shape do
    object(%{
      "view_name" => :id,
      "zone_name" => :domain,
      "record_id" => :id,
      "name" => :dns_owner,
      "type" => enum(["A", "AAAA", "CNAME", "MX", "NS", "PTR", "SRV", "TXT"]),
      "ttl" => {:integer, 0, 2_147_483_647},
      "values" => list(:text)
    })
  end

  defp dns_acl do
    object(%{
      "acl_id" => :id,
      "networks" => list(:cidr),
      "action" => enum(["allow", "deny"])
    })
  end

  defp dns_provider do
    object(%{
      "provider_id" => :id,
      "provider_type" => enum(["route53", "cloudflare", "rfc2136"]),
      "endpoint" => nullable(:provider_endpoint),
      "credential_ref" => :id
    })
  end

  defp dhcp_pool, do: :dhcp_pool

  defp dhcp_pool_shape do
    object(%{
      "family" => family(),
      "pool_id" => :id,
      "subnet" => :cidr,
      "start_address" => :ip,
      "end_address" => :ip,
      "lease_seconds" => {:integer, 60, 31_536_000}
    })
  end

  defp mdns_service do
    object(%{
      "service_id" => :id,
      "name" => :nonempty_text,
      "service_type" => :service_type,
      "service_port" => {:integer, 1, 65_535},
      "txt" => list(object(%{"key" => :id, "value" => :text}))
    })
  end

  defp netboot_profile do
    object(%{
      "profile_id" => :id,
      "name" => :nonempty_text,
      "boot_asset_id" => :id,
      "arguments" => list(:text)
    })
  end

  defp netboot_device do
    object(%{"device_id" => :id, "profile_id" => :id, "mac" => :mac})
  end

  defp netboot_asset do
    object(%{
      "asset_id" => :id,
      "filename" => :normalized_relative_filename,
      "size" => nonnegative_integer(),
      "blob_digest" => :digest
    })
  end

  defp identity_policy do
    object(%{
      "policy_id" => :id,
      "action" => enum(["require_approval", "allow", "deny"]),
      "enabled" => :boolean
    })
  end

  defp settings_document do
    object(%{"service" => :id, "entries" => list(setting_entry())})
  end

  defp setting_entry, do: :setting_entry

  defp netman_profile do
    object(%{
      "profile_id" => :id,
      "name" => :nonempty_text,
      "interfaces" => list(interface_profile())
    })
  end

  defp interface_profile do
    object(%{
      "name" => :id,
      "method" => enum(["dhcp", "static", "disabled"]),
      "addresses" => list(:cidr),
      "gateway" => nullable(:ip)
    })
  end

  defp service_item, do: object(%{"service" => :id, "state" => service_state()})

  defp dns_log_item do
    object(%{
      "log_id" => :id,
      "query_name" => :domain,
      "action" => enum(["answered", "forwarded", "refused", "failed"]),
      "occurred_at" => :utc_datetime
    })
  end

  defp dhcp_lease_item, do: :dhcp_lease_item

  defp dhcp_lease_item_shape do
    object(%{
      "family" => family(),
      "lease_id" => :id,
      "address" => :ip,
      "state" => enum(["active", "expired", "released"])
    })
  end

  defp dhcp_activity_item do
    object(%{
      "activity_id" => :id,
      "family" => family(),
      "action" => enum(["lease_granted", "lease_renewed", "lease_released", "lease_expired"]),
      "occurred_at" => :utc_datetime
    })
  end

  defp mdns_discovery_item do
    object(%{"name" => :domain, "service_type" => :service_type, "address" => :ip})
  end

  defp mdns_monitor_item do
    object(%{
      "event_id" => :id,
      "name" => :domain,
      "action" => enum(["discovered", "updated", "expired"]),
      "occurred_at" => :utc_datetime
    })
  end

  defp mdns_cache_item do
    object(%{
      "name" => :domain,
      "type" => enum(["A", "AAAA", "PTR", "SRV", "TXT"]),
      "values" => list(:nonempty_text)
    })
  end

  defp netboot_transfer_item do
    object(%{
      "transfer_id" => :id,
      "asset_id" => :id,
      "device_id" => :id,
      "state" => enum(["pending", "active", "completed", "failed"])
    })
  end

  defp netboot_log_item do
    object(%{
      "log_id" => :id,
      "device_id" => :id,
      "message" => :text,
      "occurred_at" => :utc_datetime
    })
  end

  defp identity_host_item do
    object(%{
      "host_id" => :id,
      "name" => :nonempty_text,
      "state" => enum(["pending", "approved", "revoked"]),
      "revision" => :digest
    })
  end

  defp identity_approval_item do
    object(%{
      "approval_id" => :id,
      "host_id" => :id,
      "state" => enum(["pending", "approved", "revoked"])
    })
  end

  defp identity_token_item do
    object(%{
      "token_id" => :id,
      "label" => :nonempty_text,
      "state" => enum(["active", "revoked", "expired"])
    })
  end

  defp identity_audit_item do
    object(%{
      "audit_id" => :id,
      "action" => :id,
      "subject_id" => :id,
      "occurred_at" => :utc_datetime
    })
  end

  defp profile_history_item do
    object(%{"profile_id" => :id, "revision" => :digest, "activated_at" => :utc_datetime})
  end

  defp network_link_item do
    object(%{"link_id" => :id, "name" => :id, "state" => enum(["up", "down", "unknown"])})
  end

  defp network_address_item do
    object(%{"link_id" => :id, "address" => :cidr, "scope" => enum(["global", "link", "host"])})
  end

  defp network_route_item do
    object(%{"destination" => :cidr, "gateway" => :ip, "link_id" => :id})
  end

  defp resolved_upstream_item do
    object(%{"address" => :ip, "source" => enum(["managed", "dhcp", "static"])})
  end

  defp resolved_search_domain_item do
    object(%{"domain" => :domain, "routing_only" => :boolean})
  end

  defp resolved_cache_item do
    object(%{"domain" => :domain, "address" => :ip, "expires_at" => :utc_datetime})
  end

  defp dhcp_client_lease_item do
    object(%{"connection_id" => :id, "address" => :ip, "expires_at" => :utc_datetime})
  end

  defp health_check, do: object(%{"name" => :id, "status" => health()})
  defp validation_error, do: object(%{"field" => :id, "message" => :text})

  defp config_failure do
    object(%{
      "phase" => enum(["delivery", "validation", "apply", "rollback"]),
      "reason" => :nonempty_text
    })
  end

  defp rollback_result do
    :rollback_result
  end

  defp validate_result_domain(
         %__MODULE__{name: name, result_schema: schema},
         %{"resource_type" => resource_type}
       )
       when schema in [:revisioned_resource, :deleted_resource] do
    if operation_resource_type(name) == resource_type, do: :ok, else: invalid_error()
  end

  defp validate_result_domain(
         %__MODULE__{target_type: :netman, result_schema: :apply_mode},
         %{"mode" => mode}
       ) do
    if mode in ["managed", "observe_first", "observe"], do: :ok, else: invalid_error()
  end

  defp validate_result_domain(
         %__MODULE__{target_type: :server, result_schema: :apply_mode},
         %{"mode" => mode}
       ) do
    if mode in ["managed", "standalone"], do: :ok, else: invalid_error()
  end

  defp validate_result_domain(_operation, _result), do: :ok

  defp operation_resource_type(name) do
    cond do
      String.contains?(name, ".dns.views.") ->
        "dns_view"

      String.contains?(name, ".dns.zones.") or String.contains?(name, ".dns.conflicts.") ->
        "dns_zone"

      String.contains?(name, ".dns.records.") ->
        "dns_record"

      String.contains?(name, ".dns.acls.") ->
        "dns_acl"

      String.contains?(name, ".dns.providers.") ->
        "dns_provider"

      String.contains?(name, ".dhcp.pools.") ->
        "dhcp_pool"

      String.contains?(name, ".mdns.services.") ->
        "mdns_service"

      String.contains?(name, ".netboot.profiles.") ->
        "netboot_profile"

      String.contains?(name, ".netboot.devices.") ->
        "netboot_device"

      String.contains?(name, ".netboot.assets.") ->
        "netboot_asset"

      String.contains?(name, ".identity.hosts.") ->
        "identity_host"

      String.contains?(name, ".identity.tokens.") ->
        "identity_token"

      String.contains?(name, ".identity.policies.") ->
        "identity_policy"

      String.contains?(name, ".profiles.") ->
        "netman_profile"

      true ->
        nil
    end
  end

  defp validate_type(value, {:object, required, optional}, depth)
       when is_map(value) and depth > 0 do
    with {:ok, _value} <- Bounds.map(value),
         true <- Enum.all?(Map.keys(value), &is_binary/1),
         true <- Enum.all?(Map.keys(required), &Map.has_key?(value, &1)),
         true <-
           Enum.all?(Map.keys(value), &(Map.has_key?(required, &1) or Map.has_key?(optional, &1))) do
      Enum.reduce_while(value, :ok, fn {key, nested}, :ok ->
        spec = Map.get(required, key, Map.get(optional, key))

        case validate_type(nested, spec, depth - 1) do
          :ok -> {:cont, :ok}
          _ -> {:halt, invalid_error()}
        end
      end)
    else
      _ -> invalid_error()
    end
  end

  defp validate_type(value, {:list, item, maximum}, depth) when depth > 0 do
    with {:ok, values} <- Bounds.list(value),
         true <- length(values) <= maximum do
      Enum.reduce_while(values, :ok, fn nested, :ok ->
        case validate_type(nested, item, depth - 1) do
          :ok -> {:cont, :ok}
          _ -> {:halt, invalid_error()}
        end
      end)
    else
      _ -> invalid_error()
    end
  end

  defp validate_type(nil, {:nullable, _spec}, _depth), do: :ok
  defp validate_type(value, {:nullable, spec}, depth), do: validate_type(value, spec, depth)

  defp validate_type(value, {:enum, values}, _depth) do
    if value in values, do: :ok, else: invalid_error()
  end

  defp validate_type(value, {:literal, value}, _depth), do: :ok

  defp validate_type(value, {:integer, minimum, maximum}, _depth)
       when is_integer(value) and value >= minimum and value <= maximum,
       do: :ok

  defp validate_type(value, :id, _depth), do: validate_identifier(value)
  defp validate_type(value, :text, _depth), do: validate_bounded(value, &Bounds.message/1)

  defp validate_type(value, :nonempty_text, _depth),
    do: validate_nonempty(value, &Bounds.message/1)

  defp validate_type(value, :digest, _depth), do: normalize(Digest.validate(value))
  defp validate_type(value, :utc_datetime, _depth), do: validate_utc_datetime(value)
  defp validate_type(value, :boolean, _depth) when is_boolean(value), do: :ok

  defp validate_type(value, :scalar, _depth)
       when is_nil(value) or is_boolean(value) or is_float(value),
       do: :ok

  defp validate_type(value, :scalar, _depth)
       when is_integer(value) and value >= -@max_integer and value <= @max_integer,
       do: :ok

  defp validate_type(value, :scalar, depth) when is_binary(value),
    do: validate_type(value, :text, depth)

  defp validate_type(value, :setting_scalar, _depth)
       when is_nil(value) or is_boolean(value) or is_float(value),
       do: :ok

  defp validate_type(value, :setting_scalar, _depth)
       when is_integer(value) and value >= -@max_integer and value <= @max_integer,
       do: :ok

  defp validate_type(value, :setting_scalar, depth) when is_binary(value),
    do: validate_type(value, :setting_text, depth)

  defp validate_type(value, :setting_text, depth) do
    with :ok <- validate_type(value, :text, depth),
         {:ok, normalized} <- normalize_unicode(value),
         true <- printable_setting_text?(normalized),
         false <- raw_transport_body?(normalized),
         false <- local_path_value?(normalized) do
      :ok
    else
      _ -> invalid_error()
    end
  end

  defp validate_type(value, :filename, _depth) do
    with :ok <- validate_type(value, :nonempty_text, 0),
         {:ok, normalized} <- normalize_unicode(value),
         false <- identifier_path_value?(normalized) do
      :ok
    else
      _ -> invalid_error()
    end
  end

  defp validate_type(value, :normalized_relative_filename, _depth) do
    with :ok <- validate_type(value, :nonempty_text, 0),
         true <- normalized_relative_filename?(value) do
      :ok
    else
      _ -> invalid_error()
    end
  end

  defp validate_type(value, :domain, _depth), do: validate_dns_name(value)

  defp validate_type(value, :domain_label, _depth) do
    with :ok <- validate_type(value, :nonempty_text, 0),
         true <- value in ["@", "*"] or valid_dns_label?(value) do
      :ok
    else
      _ -> invalid_error()
    end
  end

  defp validate_type(value, :dns_owner, _depth) do
    validate_dns_owner(value)
  end

  defp validate_type(value, :provider_endpoint, _depth), do: validate_provider_endpoint(value)

  defp validate_type(value, :service_type, _depth) do
    with :ok <- validate_dns_name(value),
         [service, protocol] <- String.split(value, "."),
         true <- String.starts_with?(service, "_"),
         true <- protocol in ["_tcp", "_udp"] do
      :ok
    else
      _ -> invalid_error()
    end
  end

  defp validate_type(value, :ip, _depth), do: validate_ip(value)
  defp validate_type(value, :cidr, _depth), do: validate_cidr(value)

  defp validate_type(value, :mac, _depth) do
    with :ok <- validate_type(value, :nonempty_text, 0),
         true <- Regex.match?(~r/\A(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}\z/, value) do
      :ok
    else
      _ -> invalid_error()
    end
  end

  defp validate_type(value, :dhcp_pool, depth) do
    with :ok <- validate_type(value, dhcp_pool_shape(), depth),
         {:ok, family} <- wire_family(value["family"]),
         {:ok, ^family} <- cidr_family(value["subnet"]),
         {:ok, ^family} <- ip_family(value["start_address"]),
         {:ok, ^family} <- ip_family(value["end_address"]),
         true <- coherent_pool_range?(value) do
      :ok
    else
      _ -> invalid_error()
    end
  end

  defp validate_type(value, :lease_release_result, depth) do
    shape =
      object(%{
        "family" => family(),
        "lease_id" => :id,
        "address" => :ip,
        "released" => :boolean
      })

    with :ok <- validate_type(value, shape, depth),
         true <- coherent_family_address?(value) do
      :ok
    else
      _ -> invalid_error()
    end
  end

  defp validate_type(value, :dhcp_lease_item, depth) do
    with :ok <- validate_type(value, dhcp_lease_item_shape(), depth),
         true <- coherent_family_address?(value) do
      :ok
    else
      _ -> invalid_error()
    end
  end

  defp validate_type(value, :dns_record, depth) do
    with :ok <- validate_type(value, dns_record_shape(), depth),
         [_ | _] <- value["values"],
         true <- valid_dns_record_owner?(value["type"], value["name"]),
         true <- valid_dns_record_values?(value["type"], value["values"]) do
      :ok
    else
      _ -> invalid_error()
    end
  end

  defp validate_type(value, :dns_zone_import, depth) do
    source =
      object(%{
        "view_name" => :id,
        "zone_name" => :domain,
        "source_type" => enum(["provider", "snapshot"]),
        "source_id" => :id,
        "source_revision" => :digest
      })

    blob =
      object(%{
        "view_name" => :id,
        "zone_name" => :domain,
        "filename" => :filename,
        "size" => nonnegative_integer(),
        "blob_digest" => :digest
      })

    case validate_type(value, source, depth) do
      :ok -> :ok
      _ -> validate_type(value, blob, depth)
    end
  end

  defp validate_type(value, :setting_entry, depth) do
    with :ok <- validate_type(value, object(%{"key" => :id, "value" => :setting_value}), depth),
         true <- safe_setting_name?(value["key"]),
         true <- safe_setting_value?(value["key"], value["value"]) do
      :ok
    else
      _ -> invalid_error()
    end
  end

  defp validate_type(value, :setting_value, depth) when depth > 0 do
    case value do
      %{"type" => "string", "value" => _value} ->
        validate_type(
          value,
          object(%{"type" => {:literal, "string"}, "value" => :setting_text}),
          depth
        )

      %{"type" => "integer", "value" => _value} ->
        validate_type(
          value,
          object(%{
            "type" => {:literal, "integer"},
            "value" => {:integer, -@max_integer, @max_integer}
          }),
          depth
        )

      %{"type" => "boolean", "value" => _value} ->
        validate_type(
          value,
          object(%{"type" => {:literal, "boolean"}, "value" => :boolean}),
          depth
        )

      %{"type" => "null", "value" => nil} ->
        validate_type(
          value,
          object(%{"type" => {:literal, "null"}, "value" => {:literal, nil}}),
          depth
        )

      %{"type" => "list", "items" => _items} ->
        validate_type(
          value,
          object(%{"type" => {:literal, "list"}, "items" => list(:setting_scalar)}),
          depth
        )

      %{"type" => "object", "entries" => _entries} ->
        validate_type(
          value,
          object(%{"type" => {:literal, "object"}, "entries" => list(setting_entry())}),
          depth
        )

      _ ->
        invalid_error()
    end
  end

  defp validate_type(value, :rollback_result, depth) do
    shape =
      object(%{
        "succeeded" => :boolean,
        "restored_version" => nullable(positive_integer()),
        "restored_revision" => nullable(:digest),
        "reason" => nullable(:nonempty_text)
      })

    with :ok <- validate_type(value, shape, depth),
         true <- coherent_rollback?(value) do
      :ok
    else
      _ -> invalid_error()
    end
  end

  defp validate_type(value, :config_state, depth) do
    with :ok <- validate_type(value, config_state_shape(), depth),
         true <- coherent_config_state?(value) do
      :ok
    else
      _ -> invalid_error()
    end
  end

  defp validate_type(%{"field" => "name"} = value, :profile_change, depth) do
    validate_type(
      value,
      object(%{"field" => {:literal, "name"}, "value" => :nonempty_text}),
      depth
    )
  end

  defp validate_type(%{"field" => "method"} = value, :profile_change, depth) do
    validate_type(
      value,
      object(%{
        "field" => {:literal, "method"},
        "interface" => :id,
        "value" => enum(["dhcp", "static", "disabled"])
      }),
      depth
    )
  end

  defp validate_type(%{"field" => "addresses"} = value, :profile_change, depth) do
    validate_type(
      value,
      object(%{
        "field" => {:literal, "addresses"},
        "interface" => :id,
        "value" => list(:cidr)
      }),
      depth
    )
  end

  defp validate_type(%{"field" => "gateway"} = value, :profile_change, depth) do
    validate_type(
      value,
      object(%{
        "field" => {:literal, "gateway"},
        "interface" => :id,
        "value" => nullable(:ip)
      }),
      depth
    )
  end

  defp validate_type(value, :revisioned_resource, depth) when is_map(value) and depth > 0 do
    with {:ok, _value} <- Bounds.map(value),
         true <-
           Map.keys(value) |> Enum.sort() == [
             "resource",
             "resource_id",
             "resource_type",
             "revision"
           ],
         :ok <- validate_type(value["resource_type"], resource_type(), depth - 1),
         :ok <- validate_type(value["resource_id"], :id, depth - 1),
         :ok <- validate_type(value["revision"], :digest, depth - 1),
         spec when not is_nil(spec) <- resource_spec(value["resource_type"]),
         :ok <- validate_type(value["resource"], spec, depth - 1),
         {:ok, identifier} <- resource_identifier(value["resource_type"], value["resource"]),
         true <- value["resource_id"] == identifier do
      :ok
    else
      _ -> invalid_error()
    end
  end

  defp validate_type(value, :deleted_resource, depth) when is_map(value) and depth > 0 do
    with {:ok, _value} <- Bounds.map(value),
         true <-
           Map.keys(value) |> Enum.sort() == [
             "resource_id",
             "resource_ref",
             "resource_type",
             "revision"
           ],
         :ok <- validate_type(value["resource_type"], resource_type(), depth - 1),
         :ok <- validate_type(value["resource_id"], :id, depth - 1),
         :ok <- validate_type(value["revision"], :digest, depth - 1),
         spec when not is_nil(spec) <- resource_ref_spec(value["resource_type"]),
         :ok <- validate_type(value["resource_ref"], spec, depth - 1),
         {:ok, identifier} <- resource_identifier(value["resource_type"], value["resource_ref"]),
         true <- value["resource_id"] == identifier do
      :ok
    else
      _ -> invalid_error()
    end
  end

  defp validate_type(_value, _spec, _depth), do: invalid_error()

  defp resource_spec("dns_view"), do: dns_view()
  defp resource_spec("dns_zone"), do: dns_zone()
  defp resource_spec("dns_record"), do: dns_record()
  defp resource_spec("dns_acl"), do: dns_acl()
  defp resource_spec("dns_provider"), do: dns_provider()
  defp resource_spec("dhcp_pool"), do: dhcp_pool()
  defp resource_spec("mdns_service"), do: mdns_service()
  defp resource_spec("netboot_profile"), do: netboot_profile()
  defp resource_spec("netboot_device"), do: netboot_device()
  defp resource_spec("netboot_asset"), do: netboot_asset()
  defp resource_spec("identity_host"), do: identity_host_item()
  defp resource_spec("identity_token"), do: identity_token_item()
  defp resource_spec("identity_policy"), do: identity_policy()
  defp resource_spec("netman_profile"), do: netman_profile()
  defp resource_spec(_resource_type), do: nil

  defp resource_ref_spec("dns_view"), do: object(%{"view_name" => :id})

  defp resource_ref_spec("dns_zone"),
    do: object(%{"view_name" => :id, "zone_name" => :domain})

  defp resource_ref_spec("dns_record"), do: dns_record_ref()
  defp resource_ref_spec("dns_acl"), do: object(%{"acl_id" => :id})
  defp resource_ref_spec("dns_provider"), do: object(%{"provider_id" => :id})
  defp resource_ref_spec("dhcp_pool"), do: family_ref("pool_id")
  defp resource_ref_spec("mdns_service"), do: object(%{"service_id" => :id})
  defp resource_ref_spec("netboot_profile"), do: object(%{"profile_id" => :id})
  defp resource_ref_spec("netboot_device"), do: object(%{"device_id" => :id})
  defp resource_ref_spec("netboot_asset"), do: object(%{"asset_id" => :id})
  defp resource_ref_spec("identity_host"), do: object(%{"host_id" => :id})
  defp resource_ref_spec("identity_token"), do: object(%{"token_id" => :id})
  defp resource_ref_spec("identity_policy"), do: object(%{"policy_id" => :id})
  defp resource_ref_spec("netman_profile"), do: object(%{"profile_id" => :id})
  defp resource_ref_spec(_resource_type), do: nil

  defp resource_identifier("dns_view", resource), do: Map.fetch(resource, "view_name")
  defp resource_identifier("dns_zone", resource), do: Map.fetch(resource, "zone_name")
  defp resource_identifier("dns_record", resource), do: Map.fetch(resource, "record_id")
  defp resource_identifier("dns_acl", resource), do: Map.fetch(resource, "acl_id")
  defp resource_identifier("dns_provider", resource), do: Map.fetch(resource, "provider_id")
  defp resource_identifier("dhcp_pool", resource), do: Map.fetch(resource, "pool_id")
  defp resource_identifier("mdns_service", resource), do: Map.fetch(resource, "service_id")
  defp resource_identifier("netboot_profile", resource), do: Map.fetch(resource, "profile_id")
  defp resource_identifier("netboot_device", resource), do: Map.fetch(resource, "device_id")
  defp resource_identifier("netboot_asset", resource), do: Map.fetch(resource, "asset_id")
  defp resource_identifier("identity_host", resource), do: Map.fetch(resource, "host_id")
  defp resource_identifier("identity_token", resource), do: Map.fetch(resource, "token_id")
  defp resource_identifier("identity_policy", resource), do: Map.fetch(resource, "policy_id")
  defp resource_identifier("netman_profile", resource), do: Map.fetch(resource, "profile_id")
  defp resource_identifier(_resource_type, _resource), do: :error

  defp transport_safe(value, depth) when is_map(value) and depth > 0 do
    with {:ok, _value} <- Bounds.map(value),
         true <- Enum.all?(Map.keys(value), &safe_key?/1) do
      Enum.reduce_while(value, :ok, fn {_key, nested}, :ok ->
        case transport_safe(nested, depth - 1) do
          :ok -> {:cont, :ok}
          _ -> {:halt, invalid_error()}
        end
      end)
    else
      _ -> invalid_error()
    end
  end

  defp transport_safe(value, depth) when is_list(value) and depth > 0 do
    with {:ok, values} <- Bounds.list(value) do
      Enum.reduce_while(values, :ok, fn nested, :ok ->
        case transport_safe(nested, depth - 1) do
          :ok -> {:cont, :ok}
          _ -> {:halt, invalid_error()}
        end
      end)
    else
      _ -> invalid_error()
    end
  end

  defp transport_safe(value, _depth)
       when is_binary(value) or is_float(value) or is_boolean(value) or is_nil(value),
       do: :ok

  defp transport_safe(value, _depth)
       when is_integer(value) and value >= -@max_integer and value <= @max_integer,
       do: :ok

  defp transport_safe(_value, _depth), do: invalid_error()

  defp safe_key?(key) when is_binary(key) do
    with {:ok, key} <- Bounds.message(key),
         {:ok, key} <- normalize_unicode(key),
         normalized when normalized != "" <- normalize_transport_name(key) do
      not MapSet.member?(@forbidden_keys, normalized)
    else
      _ -> false
    end
  end

  defp safe_key?(_key), do: false

  defp safe_setting_name?(name) do
    with {:ok, name} <- Bounds.message(name),
         true <- Regex.match?(@canonical_setting_key, name),
         canonical <- normalize_transport_name(name),
         true <- canonical != "",
         false <- Enum.any?(@forbidden_setting_phrases, &String.contains?(canonical, &1)),
         true <- safe_setting_tokens?(name) do
      name
      |> setting_name_tokens()
      |> Enum.all?(&(not MapSet.member?(@forbidden_setting_tokens, &1)))
    else
      _ -> false
    end
  end

  defp setting_name_tokens(name) do
    name
    |> String.split("_")
    |> Enum.map(&normalize_material_token/1)
  end

  defp safe_setting_tokens?(name) do
    with {:ok, parsed} <- parsed_setting_name(name) do
      material? = material_setting?(parsed)

      not Enum.any?(parsed.tokens, &(&1 in ["ref", "reference"])) or
        (material? and parsed.reference_form == :id)
    else
      _ -> false
    end
  end

  defp safe_setting_value?(name, value) do
    with {:ok, parsed} <- parsed_setting_name(name) do
      if material_setting?(parsed) do
        safe_material_setting_value?(parsed.reference_form, value)
      else
        true
      end
    else
      _ -> false
    end
  end

  defp safe_material_setting_value?(nil, %{"type" => type})
       when type in ["boolean", "integer", "null"],
       do: true

  defp safe_material_setting_value?(reference_form, %{"type" => "string", "value" => value}),
    do: valid_material_reference?(reference_form, value)

  defp safe_material_setting_value?(_reference_form, %{"type" => type})
       when type in ["list", "object"],
       do: false

  defp safe_material_setting_value?(_reference_form, _value), do: false

  defp parsed_setting_name(name) do
    with true <- is_binary(name) and Regex.match?(@canonical_setting_key, name),
         [_ | _] = tokens <- setting_name_tokens(name),
         {:ok, base_tokens, suffix} <-
           split_setting_reference(tokens, not String.contains?(name, "_")) do
      {:ok,
       %{
         base: Enum.join(base_tokens),
         base_tokens: base_tokens,
         reference_form: reference_form(suffix),
         separatorless?: not String.contains?(name, "_"),
         tokens: tokens
       }}
    else
      _ -> :error
    end
  end

  defp split_setting_reference(tokens, separatorless?) do
    case List.pop_at(tokens, -1) do
      {suffix, base_tokens} when suffix in @material_reference_suffixes ->
        {:ok, base_tokens, suffix}

      _ ->
        if glued_reference_suffix?(tokens, separatorless?) do
          :error
        else
          {:ok, tokens, nil}
        end
    end
  end

  defp glued_reference_suffix?(tokens, separatorless?) do
    case List.pop_at(tokens, -1) do
      {last, prefix} ->
        Enum.any?(@glued_reference_suffixes, fn suffix ->
          if last != suffix and String.ends_with?(last, suffix) do
            stem = last |> String.replace_suffix(suffix, "") |> normalize_material_token()
            stem != "" and material_tokens?(prefix ++ [stem], separatorless?)
          else
            false
          end
        end)

      _ ->
        false
    end
  end

  defp normalize_material_token(token), do: Map.get(@material_plural_tokens, token, token)

  defp material_setting?(parsed) do
    material_tokens?(parsed.base_tokens, parsed.separatorless?)
  end

  defp material_tokens?(tokens, separatorless?) do
    Enum.any?(tokens, &MapSet.member?(@material_tokens, &1)) or
      material_token_sequence?(tokens) or
      Enum.any?(tokens, &compact_material_base?/1) or
      (separatorless? and compact_material_base?(Enum.join(tokens)))
  end

  defp material_token_sequence?(tokens) do
    tokens
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.any?(fn
      ["pkcs", "12"] -> true
      [prefix, "key"] -> MapSet.member?(@private_key_prefixes, prefix)
      _pair -> false
    end)
  end

  defp compact_material_base?(compact) do
    compact_material_root?(compact) or
      Enum.any?(@separatorless_material_roots, fn root ->
        String.starts_with?(compact, root) or String.ends_with?(compact, root)
      end)
  end

  defp compact_material_root?(compact) do
    singular = Map.get(@material_plural_tokens, compact, compact)

    MapSet.member?(@material_tokens, singular) or
      Enum.any?(@private_key_prefixes, fn prefix ->
        compact in [prefix <> "key", prefix <> "keys"]
      end)
  end

  defp reference_form(suffix) when suffix in ["uri", "url"], do: :uri
  defp reference_form(suffix) when suffix in ["digest", "hash"], do: :digest
  defp reference_form(suffix) when suffix in ["id", "ref"], do: :id
  defp reference_form(_suffix), do: nil

  defp valid_material_reference?(:uri, value), do: validate_provider_endpoint(value) == :ok
  defp valid_material_reference?(:digest, value), do: normalize(Digest.validate(value)) == :ok
  defp valid_material_reference?(:id, value), do: validate_identifier(value) == :ok
  defp valid_material_reference?(_form, _value), do: false

  defp validate_identifier(value) do
    with :ok <- validate_nonempty(value, &Bounds.id/1),
         {:ok, normalized} <- normalize_unicode(value),
         false <- identifier_path_value?(normalized) do
      :ok
    else
      _ -> invalid_error()
    end
  end

  defp validate_provider_endpoint(value) do
    with :ok <- validate_type(value, :nonempty_text, 0),
         {:ok, normalized} <- normalize_unicode(value),
         true <- normalized == value,
         true <- supported_http_uri?(value) do
      :ok
    else
      _ -> invalid_error()
    end
  end

  defp object(required, optional \\ %{}), do: {:object, required, optional}
  defp list(item, maximum \\ @max_collection_size), do: {:list, item, maximum}
  defp nullable(spec), do: {:nullable, spec}
  defp enum(values), do: {:enum, values}
  defp family, do: enum(["ipv4", "ipv6"])
  defp health, do: enum(["healthy", "degraded", "unhealthy"])
  defp service_state, do: enum(["running", "stopped", "failed"])
  defp connection_state, do: enum(["activated", "deactivated", "failed"])

  defp resource_type,
    do:
      enum([
        "dns_view",
        "dns_zone",
        "dns_record",
        "dns_acl",
        "dns_provider",
        "dhcp_pool",
        "mdns_service",
        "netboot_profile",
        "netboot_device",
        "netboot_asset",
        "identity_host",
        "identity_token",
        "identity_policy",
        "netman_profile"
      ])

  defp nonnegative_integer, do: {:integer, 0, @max_integer}
  defp positive_integer, do: {:integer, 1, @max_integer}

  defp validate_config_version(version, :config)
       when is_integer(version) and version >= 1 and version <= @max_integer,
       do: :ok

  defp validate_config_version(nil, kind) when kind in [:query, :command], do: :ok
  defp validate_config_version(_version, _kind), do: invalid_error()

  defp validate_bounded(value, validator) do
    case validator.(value) do
      {:ok, _value} -> :ok
      _ -> invalid_error()
    end
  end

  defp validate_nonempty(value, validator) do
    with {:ok, value} <- validator.(value),
         true <- value != "" do
      :ok
    else
      _ -> invalid_error()
    end
  end

  defp validate_utc_datetime(value) when is_binary(value) do
    with {:ok, _datetime, 0} <- DateTime.from_iso8601(value),
         true <- String.ends_with?(value, "Z") do
      :ok
    else
      _ -> invalid_error()
    end
  end

  defp validate_utc_datetime(_value), do: invalid_error()

  defp validate_ip(value) do
    with :ok <- validate_type(value, :nonempty_text, 0),
         {:ok, _address} <- :inet.parse_address(String.to_charlist(value)) do
      :ok
    else
      _ -> invalid_error()
    end
  end

  defp validate_cidr(value) do
    with :ok <- validate_type(value, :nonempty_text, 0),
         [address, prefix] <- String.split(value, "/", parts: 2),
         {:ok, parsed} <- :inet.parse_address(String.to_charlist(address)),
         {prefix, ""} <- Integer.parse(prefix),
         true <- valid_prefix?(parsed, prefix) do
      :ok
    else
      _ -> invalid_error()
    end
  end

  defp valid_prefix?(address, prefix) when tuple_size(address) == 4, do: prefix in 0..32
  defp valid_prefix?(address, prefix) when tuple_size(address) == 8, do: prefix in 0..128
  defp valid_prefix?(_address, _prefix), do: false

  defp wire_family("ipv4"), do: {:ok, :ipv4}
  defp wire_family("ipv6"), do: {:ok, :ipv6}
  defp wire_family(_family), do: invalid_error()

  defp ip_family(value) do
    with :ok <- validate_type(value, :nonempty_text, 0),
         {:ok, parsed} <- :inet.parse_address(String.to_charlist(value)) do
      parsed_family(parsed)
    else
      _ -> invalid_error()
    end
  end

  defp cidr_family(value) do
    with :ok <- validate_type(value, :nonempty_text, 0),
         [address, prefix] <- String.split(value, "/", parts: 2),
         {:ok, parsed} <- :inet.parse_address(String.to_charlist(address)),
         {prefix, ""} <- Integer.parse(prefix),
         true <- valid_prefix?(parsed, prefix) do
      parsed_family(parsed)
    else
      _ -> invalid_error()
    end
  end

  defp coherent_family_address?(%{"family" => family, "address" => address}) do
    with {:ok, expected} <- wire_family(family),
         {:ok, actual} <- ip_family(address) do
      expected == actual
    else
      _ -> false
    end
  end

  defp coherent_family_address?(_value), do: false

  defp coherent_pool_range?(%{
         "subnet" => subnet,
         "start_address" => start_address,
         "end_address" => end_address
       }) do
    with {:ok, subnet_address, prefix, bits} <- parse_cidr(subnet),
         {:ok, start_address} <- parse_address(start_address),
         {:ok, end_address} <- parse_address(end_address),
         true <- tuple_size(subnet_address) == tuple_size(start_address),
         true <- tuple_size(subnet_address) == tuple_size(end_address) do
      host_bits = bits - prefix
      subnet_integer = address_integer(subnet_address)
      first = (subnet_integer >>> host_bits) <<< host_bits
      last = first + (1 <<< host_bits) - 1
      start_integer = address_integer(start_address)
      end_integer = address_integer(end_address)

      start_integer >= first and start_integer <= last and end_integer >= first and
        end_integer <= last and start_integer <= end_integer
    else
      _ -> false
    end
  end

  defp coherent_pool_range?(_value), do: false

  defp parse_cidr(value) do
    with [address, prefix] <- String.split(value, "/", parts: 2),
         {:ok, parsed} <- parse_address(address),
         {prefix, ""} <- Integer.parse(prefix),
         true <- valid_prefix?(parsed, prefix) do
      bits = if tuple_size(parsed) == 4, do: 32, else: 128
      {:ok, parsed, prefix, bits}
    else
      _ -> invalid_error()
    end
  end

  defp parse_address(value), do: :inet.parse_address(String.to_charlist(value))

  defp address_integer(address) do
    base = if tuple_size(address) == 4, do: 256, else: 65_536
    address |> Tuple.to_list() |> Enum.reduce(0, &(&2 * base + &1))
  end

  defp parsed_family(address) when tuple_size(address) == 4, do: {:ok, :ipv4}
  defp parsed_family(address) when tuple_size(address) == 8, do: {:ok, :ipv6}
  defp parsed_family(_address), do: invalid_error()

  defp validate_dns_name(value) do
    with :ok <- validate_type(value, :nonempty_text, 0),
         name <- strip_optional_trailing_dot(value),
         true <- name != "",
         true <- byte_size(name) <= 253,
         labels <- String.split(name, ".", trim: false),
         true <- Enum.all?(labels, &valid_dns_label?/1) do
      :ok
    else
      _ -> invalid_error()
    end
  end

  defp strip_optional_trailing_dot(value) do
    if String.ends_with?(value, ".") do
      binary_part(value, 0, byte_size(value) - 1)
    else
      value
    end
  end

  defp valid_dns_label?(label) when byte_size(label) in 1..63 do
    Regex.match?(~r/\A[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\z/, label) or
      Regex.match?(~r/\A_[A-Za-z0-9](?:[A-Za-z0-9-]{0,60}[A-Za-z0-9])?\z/, label)
  end

  defp valid_dns_label?(_label), do: false

  defp validate_dns_owner("@"), do: :ok
  defp validate_dns_owner("*"), do: :ok

  defp validate_dns_owner("*." <> remainder) do
    validate_dns_name(remainder)
  end

  defp validate_dns_owner(value), do: validate_dns_name(value)

  defp valid_dns_record_owner?("SRV", owner), do: valid_srv_owner?(owner)
  defp valid_dns_record_owner?(_type, _owner), do: true

  defp valid_srv_owner?(owner) do
    owner = strip_optional_trailing_dot(owner)

    case String.split(owner, ".", trim: false) do
      [service, protocol | domain_labels] ->
        String.starts_with?(service, "_") and valid_dns_label?(service) and
          protocol in ["_tcp", "_udp"] and
          Enum.all?(domain_labels, &valid_dns_host_label?/1)

      _ ->
        false
    end
  end

  defp valid_dns_record_values?("CNAME", [value]), do: valid_dns_rdata?("CNAME", value)
  defp valid_dns_record_values?("CNAME", _values), do: false

  defp valid_dns_record_values?("MX", values) do
    if "0 ." in values do
      values == ["0 ."]
    else
      Enum.all?(values, &valid_dns_rdata?("MX", &1))
    end
  end

  defp valid_dns_record_values?("SRV", values) do
    if "0 0 0 ." in values do
      values == ["0 0 0 ."]
    else
      Enum.all?(values, &valid_dns_rdata?("SRV", &1))
    end
  end

  defp valid_dns_record_values?(type, values),
    do: Enum.all?(values, &valid_dns_rdata?(type, &1))

  defp valid_dns_rdata?("A", value), do: valid_ip_family?(value, :ipv4)
  defp valid_dns_rdata?("AAAA", value), do: valid_ip_family?(value, :ipv6)

  defp valid_dns_rdata?(type, value) when type in ["CNAME", "NS", "PTR"],
    do: validate_dns_name(value) == :ok

  defp valid_dns_rdata?("MX", value) do
    case String.split(value, " ", trim: false) do
      [priority, "."] ->
        parse_dns_integer(priority) == {:ok, 0}

      [priority, exchange] ->
        valid_dns_integer?(priority) and validate_dns_name(exchange) == :ok

      _ ->
        false
    end
  end

  defp valid_dns_rdata?("SRV", value) do
    case String.split(value, " ", trim: false) do
      ["0", "0", "0", "."] ->
        true

      [_priority, _weight, _port, "."] ->
        false

      [priority, weight, port, target] ->
        Enum.all?([priority, weight, port], &valid_dns_integer?/1) and
          validate_dns_name(target) == :ok

      _ ->
        false
    end
  end

  defp valid_dns_rdata?("TXT", _value), do: true
  defp valid_dns_rdata?(_type, _value), do: false

  defp valid_ip_family?(value, family), do: ip_family(value) == {:ok, family}

  defp valid_dns_integer?(value) do
    match?({:ok, _integer}, parse_dns_integer(value))
  end

  defp parse_dns_integer(value) do
    case Integer.parse(value) do
      {integer, ""} when integer in 0..65_535 ->
        if Integer.to_string(integer) == value, do: {:ok, integer}, else: :error

      _ ->
        :error
    end
  end

  defp coherent_config_state?(%{
         "state" => "delivered",
         "applied_revision" => nil,
         "previous_version" => nil,
         "previous_revision" => nil,
         "failure" => nil,
         "rollback" => nil
       }),
       do: true

  defp coherent_config_state?(
         %{
           "state" => "applying",
           "applied_revision" => nil,
           "failure" => nil,
           "rollback" => nil
         } = state
       ),
       do: coherent_previous_pair?(state)

  defp coherent_config_state?(
         %{
           "state" => "applied",
           "applied_revision" => applied_revision,
           "failure" => nil,
           "rollback" => nil
         } = state
       )
       when is_binary(applied_revision),
       do: coherent_previous_pair?(state)

  defp coherent_config_state?(%{"state" => "failed"} = state),
    do: coherent_failed_config_state?(state)

  defp coherent_config_state?(_state), do: false

  defp coherent_previous_pair?(%{
         "version" => version,
         "previous_version" => nil,
         "previous_revision" => nil
       })
       when is_integer(version),
       do: true

  defp coherent_previous_pair?(%{
         "version" => version,
         "previous_version" => previous_version,
         "previous_revision" => previous_revision
       })
       when is_integer(version) and is_integer(previous_version) and previous_version < version and
              is_binary(previous_revision),
       do: true

  defp coherent_previous_pair?(_state), do: false

  defp coherent_failed_config_state?(%{
         "applied_revision" => nil,
         "previous_version" => nil,
         "previous_revision" => nil,
         "failure" => %{"phase" => phase},
         "rollback" => nil
       })
       when phase in ["delivery", "validation", "apply"],
       do: true

  defp coherent_failed_config_state?(%{
         "version" => version,
         "applied_revision" => nil,
         "previous_version" => previous_version,
         "previous_revision" => previous_revision,
         "failure" => %{"phase" => "apply"},
         "rollback" => rollback
       })
       when is_integer(version) and is_integer(previous_version) and previous_version < version and
              is_binary(previous_revision) and is_map(rollback),
       do:
         not rollback["succeeded"] or
           (rollback["restored_version"] == previous_version and
              rollback["restored_revision"] == previous_revision)

  defp coherent_failed_config_state?(%{
         "version" => version,
         "applied_revision" => nil,
         "previous_version" => previous_version,
         "previous_revision" => previous_revision,
         "failure" => %{"phase" => "rollback"},
         "rollback" => %{"succeeded" => false}
       })
       when is_integer(version) and is_integer(previous_version) and previous_version < version and
              is_binary(previous_revision),
       do: true

  defp coherent_failed_config_state?(_state), do: false

  defp coherent_rollback?(%{
         "succeeded" => true,
         "restored_version" => restored_version,
         "restored_revision" => restored_revision,
         "reason" => nil
       })
       when is_integer(restored_version) and is_binary(restored_revision),
       do: true

  defp coherent_rollback?(%{
         "succeeded" => false,
         "restored_version" => nil,
         "restored_revision" => nil,
         "reason" => reason
       })
       when is_binary(reason),
       do: true

  defp coherent_rollback?(_rollback), do: false

  defp normalize_transport_name(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]/u, "")
  end

  defp local_path_value?(value) do
    not supported_http_uri?(value) and not valid_cidr_value?(value) and
      identifier_path_value?(value)
  end

  defp identifier_path_value?(value) do
    String.contains?(value, ["/", "\\"]) or
      Regex.match?(~r/\A[A-Za-z]:/, value) or
      value in [".", "..", "~"]
  end

  defp normalized_relative_filename?(value) do
    parts = String.split(value, "/", trim: false)

    String.normalize(value, :nfc) == value and
      String.printable?(value) and
      not Regex.match?(~r/\p{Cc}/u, value) and
      not String.contains?(value, ["\\", <<0>>]) and
      not Regex.match?(~r/\A[A-Za-z]:/, value) and
      Enum.all?(parts, &(&1 not in ["", ".", ".."]))
  end

  defp supported_http_uri?(value) do
    with true <- String.starts_with?(value, ["http://", "https://"]),
         false <- String.contains?(value, "%"),
         false <- String.contains?(value, "\\"),
         false <- Regex.match?(~r/[\s\p{C}]/u, value),
         {:ok, %URI{} = uri} <- URI.new(value),
         %URI{scheme: scheme, host: host, port: port, userinfo: nil, fragment: nil} <- uri,
         true <- scheme in ["http", "https"],
         true <- is_binary(host),
         true <- valid_provider_host?(host),
         true <- valid_provider_port?(port),
         true <- safe_uri_path?(uri.path),
         true <- URI.to_string(uri) == value do
      true
    else
      _ -> false
    end
  end

  defp safe_uri_path?(nil), do: true

  defp safe_uri_path?(path) do
    path
    |> String.split("/", trim: false)
    |> Enum.all?(&(&1 not in [".", ".."]))
  end

  defp valid_provider_host?(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, address} when tuple_size(address) in [4, 8] -> true
      _ -> not Regex.match?(~r/\A[0-9.]+\z/, host) and valid_dns_host?(host)
    end
  end

  defp valid_dns_host?(host) do
    host = strip_optional_trailing_dot(host)

    host != "" and byte_size(host) <= 253 and
      host
      |> String.split(".", trim: false)
      |> Enum.all?(&valid_dns_host_label?/1)
  end

  defp valid_dns_host_label?(label) when byte_size(label) in 1..63 do
    Regex.match?(~r/\A[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\z/, label)
  end

  defp valid_dns_host_label?(_label), do: false

  defp valid_provider_port?(nil), do: true
  defp valid_provider_port?(port) when is_integer(port), do: port in 1..65_535
  defp valid_provider_port?(_port), do: false

  defp valid_cidr_value?(value), do: validate_cidr(value) == :ok

  defp raw_transport_body?(value) do
    value
    |> String.upcase()
    |> String.contains?("-----BEGIN ")
  end

  defp printable_setting_text?(value), do: not Regex.match?(~r/\p{C}/u, value)

  defp normalize_unicode(value) do
    case :unicode.characters_to_nfkc_binary(value) do
      normalized when is_binary(normalized) -> {:ok, normalized}
      _ -> invalid_error()
    end
  rescue
    _ -> invalid_error()
  end

  defp normalize({:ok, _value}), do: :ok
  defp normalize(_error), do: invalid_error()

  defp invalid_error, do: {:error, Error.new(:invalid, "invalid value", %{})}
end
