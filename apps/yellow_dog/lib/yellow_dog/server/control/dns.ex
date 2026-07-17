defmodule YellowDog.Server.Control.Dns do
  @moduledoc false

  alias YellowDog.Server.Control.Revision
  alias YellowDog.Sync.Bounds
  alias YellowDog.Sync.Error
  alias YellowDog.Sync.Operation
  alias YellowDog.Sync.ServerOperation

  @record_id_pattern ~r/\Arr-[0-9a-f]{64}\z/
  @max_control_views 1_000
  @max_acl_networks 100
  @max_rrset_entries 100
  @validation_observed_at "1970-01-01T00:00:00Z"
  @validation_revision String.duplicate("0", 64)
  @mutation_operations [
    "server.dns.views.create",
    "server.dns.views.update",
    "server.dns.views.delete",
    "server.dns.zones.create",
    "server.dns.zones.update",
    "server.dns.zones.delete",
    "server.dns.records.create",
    "server.dns.records.update",
    "server.dns.records.delete",
    "server.dns.acls.create",
    "server.dns.acls.update",
    "server.dns.acls.delete",
    "server.dns.providers.create",
    "server.dns.providers.update",
    "server.dns.providers.delete",
    "server.dns.zones.import",
    "server.dns.zones.sync",
    "server.dns.conflicts.resolve"
  ]
  @unsupported_snapshot_operations [
    "server.dns.zones.import"
  ]

  @production_dependencies %{
    view_manager: Module.concat(["YellowDog", "Dns", "ViewManager"]),
    zone_store: Module.concat(["YellowDog", "Store", "Zone"]),
    acl_registry: Module.concat(["YellowDog", "Dns", "AclRegistry"]),
    acl_codec: Module.concat(["YellowDog", "Dns", "View", "ACL"]),
    provider_store: Module.concat(["YellowDog", "Store", "Provider"]),
    provider_facade: Module.concat(["YellowDog", "DnsProvider"]),
    tasks: Module.concat(["YellowDog", "Tasks"]),
    zone_controller: Module.concat(["YellowDog", "Dns", "ZoneController"]),
    query_logger: Module.concat(["YellowDog", "Dns", "QueryLogger"]),
    metrics_collector: Module.concat(["YellowDog", "Dns", "MetricsCollector"]),
    clock: DateTime
  }
  @test_environment Mix.env() == :test

  @spec dispatch(String.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def dispatch("server.dns.views.list", payload) when is_map(payload) do
    with {:ok, items} <- read_views() do
      list_result("server.dns.views.list", items, payload, & &1["view_name"])
    end
  end

  def dispatch("server.dns.zones.list", %{"view_name" => view_name} = payload) do
    with {:ok, items} <- read_zones(view_name) do
      list_result("server.dns.zones.list", items, payload, & &1["zone_name"])
    end
  end

  def dispatch(
        "server.dns.records.list",
        %{"view_name" => view_name, "zone_name" => zone_name} = payload
      ) do
    with {:ok, items} <- read_records(view_name, zone_name) do
      list_result("server.dns.records.list", items, payload, & &1["record_id"])
    end
  end

  def dispatch("server.dns.acls.list", payload) when is_map(payload) do
    with {:ok, items} <- read_acls() do
      list_result("server.dns.acls.list", items, payload, & &1["acl_id"])
    end
  end

  def dispatch("server.dns.providers.list", payload) when is_map(payload) do
    with {:ok, items} <- read_providers() do
      list_result("server.dns.providers.list", items, payload, & &1["provider_id"])
    end
  end

  def dispatch("server.dns.logs.list", %{"view_name" => view_name} = payload) do
    with {:ok, items} <- read_logs(view_name) do
      list_result("server.dns.logs.list", items, payload, & &1["log_id"])
    end
  end

  def dispatch("server.dns.metrics.get", %{}) do
    with {:ok, metrics} <- dependency_call(:metrics_collector, :get_metrics, []),
         {:ok, result} <- metrics_result(metrics),
         {:ok, result} <- validate_operation_result("server.dns.metrics.get", result) do
      {:ok, result}
    end
  end

  def dispatch("server.dns.zones.create", payload) when is_map(payload),
    do: create_zone(payload)

  def dispatch("server.dns.zones.update", payload) when is_map(payload),
    do: update_zone(payload)

  def dispatch("server.dns.zones.delete", payload) when is_map(payload),
    do: delete_zone(payload)

  def dispatch("server.dns.zones.sync", payload) when is_map(payload),
    do: sync_zone(payload)

  def dispatch("server.dns.records.create", payload) when is_map(payload),
    do: mutate_record(:create, payload)

  def dispatch("server.dns.records.update", payload) when is_map(payload),
    do: mutate_record(:update, payload)

  def dispatch("server.dns.records.delete", payload) when is_map(payload),
    do: mutate_record(:delete, payload)

  def dispatch(
        "server.dns.providers.create",
        %{"provider_id" => _, "provider_type" => _, "endpoint" => _, "credential_ref" => _} =
          payload
      ),
      do: create_provider(payload)

  def dispatch(
        "server.dns.providers.update",
        %{"provider_id" => _, "provider_type" => _, "endpoint" => _, "credential_ref" => _} =
          payload
      ),
      do: update_provider(payload)

  def dispatch("server.dns.providers.delete", %{"provider_id" => _} = payload),
    do: delete_provider(payload)

  def dispatch("server.dns.conflicts.resolve", payload) when is_map(payload),
    do: resolve_provider_conflict(payload)

  def dispatch(operation, _payload) when operation in @mutation_operations,
    do: unsupported_error()

  def dispatch(operation, _payload) when is_binary(operation), do: unsupported_error()
  def dispatch(_operation, _payload), do: unsupported_error()

  @spec current(String.t(), map()) :: {:ok, map() | :missing} | {:error, Error.t()}
  def current(operation, %{"view_name" => view_name})
      when operation in [
             "server.dns.views.create",
             "server.dns.views.update",
             "server.dns.views.delete"
           ] do
    with {:ok, views} <- read_views() do
      current_resource(
        operation,
        Enum.find(views, &(&1["view_name"] == view_name)),
        "server.dns.views.list"
      )
    end
  end

  def current(
        operation,
        %{"view_name" => view_name, "zone_name" => zone_name}
      )
      when operation in [
             "server.dns.zones.create",
             "server.dns.zones.update",
             "server.dns.zones.delete",
             "server.dns.zones.sync"
           ] do
    with {:ok, zones} <- read_zones(view_name) do
      current_resource(
        operation,
        Enum.find(zones, &(&1["zone_name"] == canonical_name(zone_name))),
        "server.dns.zones.list"
      )
    end
  end

  def current("server.dns.conflicts.resolve", payload) when is_map(payload) do
    with {:ok, payload} <- validate_operation_payload("server.dns.conflicts.resolve", payload),
         {:ok, conflict} <- fetch_provider_conflict(payload["conflict_id"]),
         {:ok, _resource, revision_state} <- conflict_zone_revision_state(conflict) do
      {:ok, revision_state}
    end
  end

  def current(operation, %{"acl_id" => acl_id})
      when operation in [
             "server.dns.acls.create",
             "server.dns.acls.update",
             "server.dns.acls.delete"
           ] do
    with {:ok, acls} <- read_acls() do
      current_resource(
        operation,
        Enum.find(acls, &(&1["acl_id"] == acl_id)),
        "server.dns.acls.list"
      )
    end
  end

  def current(operation, %{"provider_id" => provider_id})
      when operation in [
             "server.dns.providers.create",
             "server.dns.providers.update",
             "server.dns.providers.delete"
           ] do
    case fetch_provider_resource(provider_id) do
      {:ok, resource} ->
        current_resource(operation, resource, "server.dns.providers.list")

      {:error, %Error{code: :not_found}} ->
        current_resource(operation, nil, "server.dns.providers.list")

      {:error, %Error{}} = error ->
        error
    end
  end

  def current(
        operation,
        %{
          "view_name" => view_name,
          "zone_name" => zone_name,
          "record_id" => requested_id
        } = payload
      )
      when operation in [
             "server.dns.records.create",
             "server.dns.records.update",
             "server.dns.records.delete"
           ] do
    with :ok <- validate_record_reference(operation, payload),
         {:ok, record} <- resolve_record_id(view_name, zone_name, requested_id),
         {:ok, record} <- validate_current_resource("server.dns.records.list", record) do
      {:ok, record}
    else
      {:error, %Error{code: :not_found}} when operation == "server.dns.records.create" ->
        {:ok, :missing}

      {:error, %Error{}} = error ->
        error
    end
  end

  def current(operation, _payload) when operation in @unsupported_snapshot_operations,
    do: unsupported_error()

  def current(operation, _payload) when operation in @mutation_operations, do: invalid_error()
  def current(_operation, _payload), do: unsupported_error()

  defp current_resource(operation, nil, _read_operation) do
    if String.ends_with?(operation, ".create"), do: {:ok, :missing}, else: not_found_error()
  end

  defp current_resource(_operation, resource, read_operation) do
    validate_current_resource(read_operation, resource)
  end

  defp read_views do
    with {:ok, result} <- dependency_call(:view_manager, :list_control_views, []),
         {:ok, views} <- unwrap_control_views(result) do
      views
      |> Enum.reduce_while({:ok, []}, fn view, {:ok, items} ->
        case project_view(view) do
          {:ok, item} -> {:cont, {:ok, [item | items]}}
          {:error, %Error{}} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, items} -> {:ok, Enum.sort_by(items, & &1["view_name"])}
        {:error, %Error{}} = error -> error
      end
    end
  end

  defp unwrap_control_views({:ok, views}) when is_list(views) do
    case bounded_list(views, @max_control_views) do
      {:ok, bounded} -> {:ok, bounded}
      {:error, :too_large} -> unsupported_error()
    end
  end

  defp unwrap_control_views({:error, :unsupported_acl}), do: unsupported_error()
  defp unwrap_control_views({:error, :control_snapshot_too_large}), do: unsupported_error()
  defp unwrap_control_views(_result), do: apply_failed_error()

  defp project_view(%{} = view) do
    with name when is_binary(name) <- field(view, :name, field(view, :view_name)),
         match_clients when is_list(match_clients) <- field(view, :match_clients),
         recursion when is_boolean(recursion) <- field(view, :recursion) do
      {:ok,
       %{
         "view_name" => name,
         "match_clients" => match_clients,
         "recursion" => recursion
       }}
    else
      _invalid -> invalid_error()
    end
  end

  defp project_view(_view), do: invalid_error()

  defp read_zones(view_name) do
    with {:ok, result} <- dependency_call(:zone_store, :list_zones_for_view, [view_name]),
         {:ok, zones} <- unwrap_store_list(result) do
      items =
        zones |> Enum.flat_map(&project_zone(&1, view_name)) |> Enum.sort_by(& &1["zone_name"])

      {:ok, items}
    end
  end

  defp create_zone(payload) do
    with {:ok, payload} <- validate_operation_payload("server.dns.zones.create", payload),
         payload <- canonicalize_zone_payload(payload),
         "authoritative" <- payload["zone_type"] || unsupported_error(),
         :ok <- ensure_view(payload["view_name"]),
         :missing <- fetch_zone(payload["view_name"], payload["zone_name"]),
         {:ok, cloud_mirror} <- provider_binding(payload["provider_id"]),
         soa <- dependency_module(:zone_store).default_soa(payload["zone_name"]),
         :ok <-
           store_ok(:create_zone, [
             payload["view_name"],
             payload["zone_name"],
             soa,
             zone_options(cloud_mirror)
           ]) do
      case start_authoritative_zone(payload["view_name"], payload["zone_name"]) do
        :ok -> revisioned_result("server.dns.zones.create", "dns_zone", zone_resource(payload))
        {:error, %Error{}} -> rollback_create(payload["view_name"], payload["zone_name"])
      end
    else
      "forward" -> unsupported_error()
      {:ok, _zone} -> conflict_error()
      {:error, %Error{}} = error -> error
      _invalid -> invalid_error()
    end
  end

  defp create_provider(payload) do
    with {:ok, _payload} <- validate_operation_payload("server.dns.providers.create", payload) do
      unsupported_error()
    end
  end

  defp update_provider(payload) do
    with {:ok, payload} <- validate_operation_payload("server.dns.providers.update", payload),
         :ok <- validate_provider_update(payload),
         {:ok, provider} <- fetch_provider(payload["provider_id"]),
         {:ok, stored_type} <- provider_wire_type(provider),
         true <- stored_type == payload["provider_type"] || conflict_error(),
         :ok <- provider_owner_result(:update_provider, [payload["provider_id"], %{}]) do
      revisioned_result("server.dns.providers.update", "dns_provider", payload)
    else
      {:error, %Error{}} = error -> error
      false -> conflict_error()
      _failure -> apply_failed_error()
    end
  end

  defp delete_provider(payload) do
    with {:ok, payload} <- validate_operation_payload("server.dns.providers.delete", payload),
         :ok <- provider_owner_result(:remove_provider, [payload["provider_id"]]) do
      deleted_result("server.dns.providers.delete", "dns_provider", payload)
    else
      {:error, %Error{}} = error -> error
      _failure -> apply_failed_error()
    end
  end

  defp resolve_provider_conflict(payload) do
    with {:ok, payload} <- validate_operation_payload("server.dns.conflicts.resolve", payload),
         {:ok, resolution} <- conflict_resolution(payload["resolution"]),
         {:ok, conflict} <- fetch_provider_conflict(payload["conflict_id"]),
         :ok <- provider_owner_result(:resolve_conflict, [payload["conflict_id"], resolution]),
         {:ok, resource, revision_state} <- conflict_zone_revision_state(conflict) do
      conflict_revisioned_result(resource, revision_state)
    else
      {:error, %Error{}} = error -> error
      _failure -> apply_failed_error()
    end
  end

  defp update_zone(payload) do
    with {:ok, payload} <- validate_operation_payload("server.dns.zones.update", payload),
         payload <- canonicalize_zone_payload(payload),
         {:ok, old_zone} <- fetch_zone(payload["view_name"], payload["zone_name"]),
         {:ok, "authoritative"} <- stored_zone_type(old_zone),
         "authoritative" <- payload["zone_type"] || conflict_error(),
         {:ok, cloud_mirror} <- provider_binding(payload["provider_id"]),
         attrs <- %{cloud_mirror: cloud_mirror} do
      case store_ok(:update_zone, [payload["view_name"], payload["zone_name"], attrs]) do
        :ok ->
          case reload_authoritative_zone(payload["view_name"], payload["zone_name"]) do
            :ok ->
              revisioned_result("server.dns.zones.update", "dns_zone", zone_resource(payload))

            {:error, %Error{}} = error ->
              rollback_zone_update(payload, old_zone, error)
          end

        {:error, %Error{}} = error ->
          error
      end
    else
      :missing ->
        not_found_error()

      "forward" ->
        conflict_error()

      {:ok, _other} ->
        conflict_error()

      {:error, %Error{}} = error ->
        error

      _invalid ->
        invalid_error()
    end
  end

  defp delete_zone(payload) do
    with {:ok, payload} <- validate_operation_payload("server.dns.zones.delete", payload),
         payload <- canonicalize_zone_payload(payload),
         {:ok, zone} <- fetch_zone(payload["view_name"], payload["zone_name"]),
         {:ok, "authoritative"} <- stored_zone_type(zone),
         {:ok, records} <- list_store_records(payload["view_name"], payload["zone_name"]) do
      case store_ok(:delete_zone, [payload["view_name"], payload["zone_name"]]) do
        :ok ->
          case stop_authoritative_zone(payload["view_name"], payload["zone_name"]) do
            :ok -> deleted_result("server.dns.zones.delete", "dns_zone", zone_reference(payload))
            {:error, %Error{}} = error -> rollback_zone_delete(payload, zone, records, error)
          end

        {:error, %Error{}} = error ->
          error
      end
    else
      :missing ->
        not_found_error()

      {:ok, _other} ->
        unsupported_error()

      {:error, %Error{}} = error ->
        error

      _invalid ->
        invalid_error()
    end
  end

  defp sync_zone(payload) do
    with {:ok, payload} <- validate_operation_payload("server.dns.zones.sync", payload),
         payload <- canonicalize_zone_payload(payload),
         {:ok, zone} <- authoritative_zone(payload["view_name"], payload["zone_name"]),
         {:ok, result} <- cloud_sync_result(payload, zone) do
      case dependency_call(:tasks, :enqueue_cloud_zone_sync, [
             payload["view_name"],
             payload["zone_name"],
             payload["provider_id"]
           ]) do
        {:ok, {:ok, _job}} -> {:ok, result}
        {:ok, enqueue_result} -> cloud_sync_enqueue_result(enqueue_result)
        {:error, %Error{}} = error -> error
        _failure -> apply_failed_error()
      end
    else
      {:error, %Error{}} = error -> error
      _failure -> apply_failed_error()
    end
  end

  defp mutate_record(action, payload) do
    operation = "server.dns.records.#{action}"

    with {:ok, payload} <- validate_operation_payload(operation, payload),
         payload <- canonicalize_zone_payload(payload),
         :ok <- validate_record_reference(operation, payload),
         {:ok, _zone} <- authoritative_zone(payload["view_name"], payload["zone_name"]),
         {:ok, mutation} <- record_mutation(action, payload),
         {:ok, result} <- apply_record_mutation(action, payload, mutation) do
      {:ok, result}
    else
      {:error, %Error{}} = error -> error
      _invalid -> invalid_error()
    end
  end

  defp record_mutation(:delete, payload) do
    with {:ok, record} <-
           resolve_record_id(payload["view_name"], payload["zone_name"], payload["record_id"]),
         {:ok, store_type} <- store_record_type(record["type"]),
         {:ok, old} <-
           fetch_rrset(payload["view_name"], payload["zone_name"], record["name"], store_type) do
      {:ok,
       %{
         owner: canonical_owner(record["name"]),
         type: store_type,
         old: old,
         resource: record
       }}
    end
  end

  defp record_mutation(action, payload) when action in [:create, :update] do
    owner = canonical_owner(payload["name"])

    with {:ok, store_type} <- store_record_type(payload["type"]),
         {:ok, rrset} <- encode_rrset(payload["type"], payload["values"], payload["ttl"]),
         {:ok, old} <-
           fetch_rrset_or_missing(
             payload["view_name"],
             payload["zone_name"],
             owner,
             store_type
           ),
         :ok <- ensure_record_state(action, old),
         {:ok, resource} <-
           project_record(
             %{owner: owner, type: store_type, rrset: rrset},
             payload["view_name"],
             canonical_name(payload["zone_name"])
           ) do
      {:ok,
       %{
         owner: owner,
         type: store_type,
         old: old,
         rrset: rrset,
         resource: resource
       }}
    end
  end

  defp apply_record_mutation(action, payload, mutation) do
    apply_result =
      case action do
        :delete ->
          store_ok(:delete_rrset, [
            payload["view_name"],
            payload["zone_name"],
            mutation.owner,
            mutation.type
          ])

        _ ->
          store_ok(:put_rrset, [
            payload["view_name"],
            payload["zone_name"],
            mutation.owner,
            mutation.type,
            mutation.rrset
          ])
      end

    case apply_result do
      :ok ->
        case reload_authoritative_zone(payload["view_name"], payload["zone_name"]) do
          :ok ->
            case action do
              :delete ->
                deleted_result(
                  "server.dns.records.delete",
                  "dns_record",
                  record_reference(payload)
                )

              _ ->
                revisioned_result(
                  "server.dns.records.#{action}",
                  "dns_record",
                  mutation.resource
                )
            end

          {:error, %Error{}} = error ->
            rollback_record(payload, mutation, error)
        end

      {:error, %Error{}} = error ->
        error
    end
  end

  defp rollback_zone_update(payload, old_zone, _error) do
    case store_ok(:update_zone, [payload["view_name"], payload["zone_name"], old_zone]) do
      :ok ->
        case reload_authoritative_zone(payload["view_name"], payload["zone_name"]) do
          :ok -> apply_failed_error()
          {:error, %Error{}} -> rollback_failed_error()
        end

      {:error, %Error{}} ->
        rollback_failed_error()
    end
  end

  defp rollback_zone_delete(payload, zone, records, _error) do
    with :ok <- restore_zone(payload["view_name"], payload["zone_name"], zone),
         :ok <- restore_records(payload["view_name"], payload["zone_name"], records),
         :ok <- start_authoritative_zone(payload["view_name"], payload["zone_name"]) do
      apply_failed_error()
    else
      {:error, %Error{}} -> rollback_failed_error()
    end
  end

  defp rollback_record(payload, mutation, _error) do
    with :ok <- restore_rrset(payload["view_name"], payload["zone_name"], mutation),
         :ok <- reload_authoritative_zone(payload["view_name"], payload["zone_name"]) do
      apply_failed_error()
    else
      {:error, %Error{}} -> rollback_failed_error()
    end
  end

  defp ensure_view(view_name) do
    with {:ok, views} <- read_views(),
         true <- Enum.any?(views, &(&1["view_name"] == view_name)) do
      :ok
    else
      false -> not_found_error()
      {:error, %Error{}} = error -> error
    end
  end

  defp fetch_zone(view_name, zone_name) do
    case dependency_call(:zone_store, :get_zone, [view_name, zone_name]) do
      {:ok, {:ok, zone}} when is_map(zone) -> {:ok, zone}
      {:ok, {:error, :not_found}} -> :missing
      {:ok, :error} -> :missing
      {:ok, {:error, _reason}} -> apply_failed_error()
      {:error, %Error{}} = error -> error
      _invalid -> apply_failed_error()
    end
  end

  defp authoritative_zone(view_name, zone_name) do
    with {:ok, zone} <- fetch_zone(view_name, zone_name),
         {:ok, "authoritative"} <- stored_zone_type(zone) do
      {:ok, zone}
    else
      :missing -> not_found_error()
      {:ok, _other} -> unsupported_error()
      {:error, %Error{}} = error -> error
    end
  end

  defp stored_zone_type(zone) do
    case wire_zone_type(field(zone, :zone_type)) do
      {:ok, type} -> {:ok, type}
      :error -> invalid_error()
    end
  end

  defp provider_binding(nil), do: {:ok, nil}

  defp provider_binding(provider_id) when is_binary(provider_id) do
    with {:ok, provider} <- dependency_call(:provider_store, :get_config, [provider_id]),
         {:ok, provider} <- unwrap_provider(provider),
         true <- field(provider, :enabled, true),
         {:ok, provider_type} <- wire_provider_type(field(provider, :type)) do
      {:ok,
       %{
         enabled: true,
         connector_name: provider_id,
         provider: provider_atom(provider_type),
         zone_id: "",
         direction: :pull_from_cloud,
         conflict_strategy: :cloud_wins
       }}
    else
      {:error, %Error{}} = error -> error
      false -> unsupported_error()
      :error -> unsupported_error()
      _invalid -> not_found_error()
    end
  end

  defp provider_binding(_provider_id), do: invalid_error()

  defp cloud_sync_enqueue_result({:ok, _job}), do: :ok
  defp cloud_sync_enqueue_result({:error, :invalid}), do: invalid_error()
  defp cloud_sync_enqueue_result({:error, :not_found}), do: not_found_error()
  defp cloud_sync_enqueue_result({:error, :conflict}), do: conflict_error()
  defp cloud_sync_enqueue_result({:error, :unsupported}), do: unsupported_error()
  defp cloud_sync_enqueue_result({:error, :apply_failed}), do: apply_failed_error()
  defp cloud_sync_enqueue_result({:error, :rollback_failed}), do: rollback_failed_error()
  defp cloud_sync_enqueue_result(_result), do: apply_failed_error()

  defp cloud_sync_result(payload, zone) do
    with [resource] <- project_zone(zone, payload["view_name"]),
         {:ok, revision} <- Revision.calculate(resource),
         {:ok, result} <-
           validate_operation_result("server.dns.zones.sync", %{
             "view_name" => payload["view_name"],
             "zone_name" => payload["zone_name"],
             "changed_records" => 0,
             "revision" => revision
           }) do
      {:ok, result}
    else
      _invalid -> invalid_error()
    end
  end

  defp unwrap_provider({:ok, provider}) when is_map(provider), do: {:ok, provider}
  defp unwrap_provider({:error, :not_found}), do: not_found_error()
  defp unwrap_provider({:error, _reason}), do: apply_failed_error()
  defp unwrap_provider(_result), do: apply_failed_error()

  defp provider_atom("route53"), do: :route53
  defp provider_atom("cloudflare"), do: :cloudflare

  defp validate_provider_update(%{
         "provider_id" => provider_id,
         "provider_type" => provider_type,
         "endpoint" => nil,
         "credential_ref" => credential_ref
       }) do
    cond do
      provider_type == "rfc2136" -> unsupported_error()
      credential_ref != credential_ref(provider_id) -> unsupported_error()
      true -> :ok
    end
  end

  defp validate_provider_update(_payload), do: unsupported_error()

  defp fetch_provider(provider_id) do
    with {:ok, result} <- dependency_call(:provider_facade, :fetch_provider, [provider_id]) do
      unwrap_provider(result)
    end
  end

  defp fetch_provider_conflict(conflict_id) do
    with {:ok, result} <- dependency_call(:provider_facade, :fetch_conflict, [conflict_id]) do
      case result do
        {:ok, conflict} when is_map(conflict) -> {:ok, conflict}
        {:error, :not_found} -> not_found_error()
        {:error, :conflict} -> conflict_error()
        {:error, :invalid} -> invalid_error()
        {:error, :unsupported} -> unsupported_error()
        _failure -> apply_failed_error()
      end
    end
  end

  defp conflict_zone_revision_state(conflict) do
    with zone_name when is_binary(zone_name) <- field(conflict, :zone),
         zone_name <- canonical_name(zone_name),
         true <- zone_name != "",
         {:ok, zone} <- authoritative_zone("default", zone_name),
         [resource] <- project_zone(zone, "default"),
         {:ok, resource} <- validate_current_resource("server.dns.zones.list", resource),
         {:ok, soa_serial} <- authoritative_soa_serial(zone),
         {:ok, rrsets} <- read_records("default", zone_name) do
      {:ok, resource,
       %{
         "zone" => resource,
         "soa_serial" => soa_serial,
         "rrsets" => rrsets
       }}
    else
      :missing -> not_found_error()
      {:error, %Error{}} = error -> error
      _invalid -> apply_failed_error()
    end
  end

  defp authoritative_soa_serial(zone) do
    case zone |> field(:soa, %{}) |> field(:serial) do
      serial when is_integer(serial) and serial >= 0 -> {:ok, serial}
      _invalid -> apply_failed_error()
    end
  end

  defp conflict_resolution("use_local"), do: {:ok, :use_local}
  defp conflict_resolution("use_cloud"), do: {:ok, :use_cloud}
  defp conflict_resolution(_resolution), do: invalid_error()

  defp fetch_provider_resource(provider_id) do
    with {:ok, provider} <- fetch_provider(provider_id),
         [resource] <- project_provider(provider) do
      {:ok, resource}
    else
      {:error, %Error{}} = error -> error
      _invalid -> apply_failed_error()
    end
  end

  defp provider_wire_type(provider) do
    case wire_provider_type(field(provider, :type)) do
      {:ok, type} -> {:ok, type}
      :error -> unsupported_error()
    end
  end

  defp provider_owner_result(function, arguments) do
    case dependency_call(:provider_facade, function, arguments) do
      {:ok, :ok} -> :ok
      {:ok, {:error, reason}} -> provider_owner_error(reason)
      {:error, %Error{}} = error -> error
      _invalid -> apply_failed_error()
    end
  end

  defp provider_owner_error(:not_found), do: not_found_error()
  defp provider_owner_error(:invalid), do: invalid_error()
  defp provider_owner_error(:conflict), do: conflict_error()
  defp provider_owner_error(:unsupported), do: unsupported_error()
  defp provider_owner_error(:apply_failed), do: apply_failed_error()
  defp provider_owner_error(:rollback_failed), do: rollback_failed_error()
  defp provider_owner_error(%Error{code: code}), do: provider_owner_error(code)
  defp provider_owner_error(_reason), do: apply_failed_error()

  defp zone_options(nil), do: []
  defp zone_options(cloud_mirror), do: [cloud_mirror: cloud_mirror]

  defp start_authoritative_zone(view_name, zone_name) do
    case dependency_call(:zone_controller, :start_zone, [:auth, zone_name, [view_name: view_name]]) do
      {:ok, {:ok, _pid}} -> :ok
      {:ok, :ok} -> :ok
      _failure -> apply_failed_error()
    end
  end

  defp rollback_create(view_name, zone_name) do
    stop = dependency_call(:zone_controller, :stop_zone, [view_name, :auth, zone_name])
    delete = store_ok(:delete_zone, [view_name, zone_name])

    with true <- lifecycle_ok?(stop),
         :ok <- delete,
         :missing <- fetch_zone(view_name, zone_name) do
      apply_failed_error()
    else
      _failed_cleanup -> rollback_failed_error()
    end
  end

  defp stop_authoritative_zone(view_name, zone_name) do
    case dependency_call(:zone_controller, :stop_zone, [view_name, :auth, zone_name]) do
      {:ok, :ok} -> :ok
      _failure -> apply_failed_error()
    end
  end

  defp reload_authoritative_zone(view_name, zone_name) do
    case dependency_call(:zone_controller, :reload_zone, [view_name, :auth, zone_name, []]) do
      {:ok, :ok} -> :ok
      _failure -> apply_failed_error()
    end
  end

  defp lifecycle_ok?({:ok, :ok}), do: true
  defp lifecycle_ok?({:ok, {:ok, _pid}}), do: true
  defp lifecycle_ok?({:ok, {:error, :not_found}}), do: true
  defp lifecycle_ok?(_result), do: false

  defp store_ok(function, arguments) do
    case dependency_call(:zone_store, function, arguments) do
      {:ok, :ok} -> :ok
      {:ok, {:error, :already_exists}} -> conflict_error()
      {:ok, {:error, :not_found}} -> not_found_error()
      _failure -> apply_failed_error()
    end
  end

  defp list_store_records(view_name, zone_name) do
    with {:ok, result} <- dependency_call(:zone_store, :list_records, [view_name, zone_name]),
         {:ok, records} <- unwrap_store_list(result) do
      {:ok, records}
    end
  end

  defp fetch_rrset(view_name, zone_name, owner, type) do
    owner = canonical_owner(owner)

    case dependency_call(:zone_store, :get_rrset, [view_name, zone_name, owner, type]) do
      {:ok, {:ok, record}} when is_map(record) -> {:ok, record}
      {:ok, {:error, :not_found}} -> not_found_error()
      _failure -> apply_failed_error()
    end
  end

  defp fetch_rrset_or_missing(view_name, zone_name, owner, type) do
    case fetch_rrset(view_name, zone_name, owner, type) do
      {:error, %Error{code: :not_found}} -> {:ok, :missing}
      result -> result
    end
  end

  defp ensure_record_state(:create, :missing), do: :ok
  defp ensure_record_state(:create, _old), do: conflict_error()
  defp ensure_record_state(:update, :missing), do: not_found_error()
  defp ensure_record_state(:update, _old), do: :ok

  defp restore_zone(view_name, zone_name, zone) do
    soa = field(zone, :soa)

    options =
      [
        default_ttl: field(zone, :default_ttl, 3600),
        authoritative: field(zone, :authoritative, true),
        allow_dynamic_update: field(zone, :allow_dynamic_update, false),
        serial_strategy: field(zone, :serial_strategy, :date_serial)
      ] ++ zone_options(field(zone, :cloud_mirror))

    store_ok(:create_zone, [view_name, zone_name, soa, options])
  end

  defp restore_records(view_name, zone_name, records) do
    Enum.reduce_while(records, :ok, fn record, :ok ->
      with owner when is_binary(owner) <- field(record, :owner),
           type when is_atom(type) <- field(record, :type),
           rrset when is_list(rrset) <- field(record, :rrset),
           :ok <- store_ok(:put_rrset, [view_name, zone_name, owner, type, rrset]) do
        {:cont, :ok}
      else
        _failure -> {:halt, apply_failed_error()}
      end
    end)
  end

  defp restore_rrset(view_name, zone_name, %{old: :missing} = mutation),
    do: store_ok(:delete_rrset, [view_name, zone_name, mutation.owner, mutation.type])

  defp restore_rrset(view_name, zone_name, %{old: old} = mutation) do
    case field(old, :rrset) do
      rrset when is_list(rrset) ->
        store_ok(:put_rrset, [view_name, zone_name, mutation.owner, mutation.type, rrset])

      _invalid ->
        apply_failed_error()
    end
  end

  defp validate_operation_payload(operation_name, payload) do
    with {:ok, operation} <- ServerOperation.fetch(operation_name),
         {:ok, payload} <- Operation.validate_payload(operation, payload) do
      {:ok, payload}
    else
      _invalid -> invalid_error()
    end
  end

  defp canonicalize_zone_payload(payload) do
    Map.update!(payload, "zone_name", &canonical_name/1)
  end

  defp revisioned_result(operation_name, resource_type, resource) do
    with {:ok, revision} <- Revision.calculate(resource),
         {:ok, resource_id} <- resource_identifier(resource_type, resource),
         {:ok, result} <-
           validate_operation_result(operation_name, %{
             "resource_type" => resource_type,
             "resource_id" => resource_id,
             "resource" => resource,
             "revision" => revision
           }) do
      {:ok, result}
    end
  end

  defp conflict_revisioned_result(resource, revision_state) do
    with {:ok, revision} <- Revision.calculate(revision_state),
         {:ok, resource_id} <- resource_identifier("dns_zone", resource),
         {:ok, result} <-
           validate_operation_result("server.dns.conflicts.resolve", %{
             "resource_type" => "dns_zone",
             "resource_id" => resource_id,
             "resource" => resource,
             "revision" => revision
           }) do
      {:ok, result}
    end
  end

  defp deleted_result(operation_name, resource_type, resource_ref) do
    with {:ok, revision} <- Revision.calculate(resource_ref),
         {:ok, resource_id} <- resource_identifier(resource_type, resource_ref),
         {:ok, result} <-
           validate_operation_result(operation_name, %{
             "resource_type" => resource_type,
             "resource_id" => resource_id,
             "resource_ref" => resource_ref,
             "revision" => revision
           }) do
      {:ok, result}
    end
  end

  defp resource_identifier("dns_zone", resource), do: {:ok, resource["zone_name"]}
  defp resource_identifier("dns_record", resource), do: {:ok, resource["record_id"]}
  defp resource_identifier("dns_provider", resource), do: {:ok, resource["provider_id"]}

  defp zone_reference(payload),
    do: Map.take(zone_resource(payload), ["view_name", "zone_name"])

  defp zone_resource(payload) do
    %{
      "view_name" => payload["view_name"],
      "zone_name" => canonical_name(payload["zone_name"]),
      "zone_type" => payload["zone_type"],
      "provider_id" => payload["provider_id"]
    }
  end

  defp record_reference(payload),
    do: Map.take(payload, ["view_name", "zone_name", "record_id"])

  defp project_zone(%{} = zone, fallback_view) do
    with name when is_binary(name) <- field(zone, :origin, field(zone, :name)),
         {:ok, zone_type} <- wire_zone_type(field(zone, :zone_type)),
         view_name when is_binary(view_name) <- field(zone, :view_name, fallback_view) do
      [
        %{
          "view_name" => view_name,
          "zone_name" => canonical_name(name),
          "zone_type" => zone_type,
          "provider_id" => zone_provider_id(zone)
        }
      ]
    else
      _invalid -> []
    end
  end

  defp project_zone(_zone, _fallback_view), do: []

  defp wire_zone_type(:auth), do: {:ok, "authoritative"}
  defp wire_zone_type(:authoritative), do: {:ok, "authoritative"}
  defp wire_zone_type("auth"), do: {:ok, "authoritative"}
  defp wire_zone_type("authoritative"), do: {:ok, "authoritative"}
  defp wire_zone_type(:forward), do: {:ok, "forward"}
  defp wire_zone_type("forward"), do: {:ok, "forward"}
  defp wire_zone_type(_zone_type), do: :error

  defp zone_provider_id(zone) do
    provider_id =
      case field(zone, :provider_id) do
        provider_id when is_binary(provider_id) -> provider_id
        _other -> zone |> field(:cloud_mirror, %{}) |> field(:connector_name)
      end

    if is_binary(provider_id), do: provider_id, else: nil
  end

  defp read_records(view_name, zone_name) when is_binary(zone_name) do
    zone_name = canonical_name(zone_name)

    with {:ok, result} <-
           dependency_call(:zone_store, :list_records, [view_name, zone_name]),
         {:ok, records} <- unwrap_store_list(result) do
      records
      |> Enum.reduce_while({:ok, []}, fn record, {:ok, items} ->
        case project_record(record, view_name, canonical_name(zone_name)) do
          {:ok, item} -> {:cont, {:ok, [item | items]}}
          :skip -> {:cont, {:ok, items}}
          {:error, %Error{}} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, items} -> {:ok, Enum.sort_by(items, & &1["record_id"])}
        {:error, %Error{}} = error -> error
      end
    end
  end

  defp read_records(_view_name, _zone_name), do: invalid_error()

  defp project_record(%{} = record, view_name, zone_name) do
    case wire_record_type(field(record, :type)) do
      {:ok, type} -> project_supported_record(record, view_name, zone_name, type)
      :error -> :skip
    end
  end

  defp project_record(_record, _view_name, _zone_name), do: invalid_error()

  defp project_supported_record(record, view_name, zone_name, type) do
    with owner when is_binary(owner) <- field(record, :owner),
         rrset when is_list(rrset) <- field(record, :rrset),
         {:ok, rrset} <- bounded_list(rrset, @max_rrset_entries),
         {:ok, ttl} <- record_ttl(rrset),
         {:ok, values} <- record_values(type, rrset),
         true <- values != [],
         true <- type != "CNAME" or length(values) == 1 do
      owner = canonical_owner(owner)

      {:ok,
       %{
         "view_name" => view_name,
         "zone_name" => zone_name,
         "record_id" => record_id(owner, type),
         "name" => owner,
         "type" => type,
         "ttl" => ttl,
         "values" => values
       }}
    else
      _invalid -> invalid_error()
    end
  end

  for {store, wire} <- [
        a: "A",
        aaaa: "AAAA",
        cname: "CNAME",
        mx: "MX",
        ns: "NS",
        ptr: "PTR",
        srv: "SRV",
        txt: "TXT"
      ] do
    defp wire_record_type(unquote(store)), do: {:ok, unquote(wire)}
    defp store_record_type(unquote(wire)), do: {:ok, unquote(store)}
  end

  for type <- ["A", "AAAA", "CNAME", "MX", "NS", "PTR", "SRV", "TXT"] do
    defp validate_wire_record_type(unquote(type)), do: :ok
  end

  defp wire_record_type(_type), do: :error
  defp store_record_type(_type), do: invalid_error()
  defp validate_wire_record_type(_type), do: invalid_error()

  defp encode_rrset(type, values, ttl) when is_list(values) and is_integer(ttl) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, entries} ->
      case encode_rdata(type, value) do
        {:ok, rdata} -> {:cont, {:ok, [%{rdata: rdata, ttl: ttl} | entries]}}
        :error -> {:halt, invalid_error()}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, entries |> Enum.uniq() |> Enum.sort_by(&inspect/1)}
      {:error, %Error{}} = error -> error
    end
  end

  defp encode_rrset(_type, _values, _ttl), do: invalid_error()

  defp encode_rdata(type, value) when type in ["A", "AAAA"] and is_binary(value) do
    with {:ok, address} <- parse_ip(value),
         true <- ip_matches_type?(type, address) do
      {:ok, address}
    else
      _invalid -> :error
    end
  end

  defp encode_rdata(type, value) when type in ["CNAME", "NS", "PTR"] and is_binary(value),
    do: {:ok, canonical_target(value)}

  defp encode_rdata("MX", value) when is_binary(value) do
    case String.split(value, ~r/\s+/, parts: 2, trim: true) do
      [preference, target] ->
        with {preference, ""} when preference in 0..65_535 <- Integer.parse(preference) do
          {:ok, {preference, canonical_target(target)}}
        else
          _invalid -> :error
        end

      _invalid ->
        :error
    end
  end

  defp encode_rdata("SRV", value) when is_binary(value) do
    case String.split(value, ~r/\s+/, trim: true) do
      [priority, weight, port, target] ->
        with {priority, ""} when priority in 0..65_535 <- Integer.parse(priority),
             {weight, ""} when weight in 0..65_535 <- Integer.parse(weight),
             {port, ""} when port in 0..65_535 <- Integer.parse(port) do
          {:ok, {priority, weight, port, canonical_target(target)}}
        else
          _invalid -> :error
        end

      _invalid ->
        :error
    end
  end

  defp encode_rdata("TXT", value) when is_binary(value), do: {:ok, value}
  defp encode_rdata(_type, _value), do: :error

  defp parse_ip(value) do
    case :inet.parse_address(String.to_charlist(value)) do
      {:ok, address} -> {:ok, address}
      {:error, _reason} -> :error
    end
  end

  defp ip_matches_type?("A", address), do: tuple_size(address) == 4
  defp ip_matches_type?("AAAA", address), do: tuple_size(address) == 8

  defp canonical_target("."), do: "."
  defp canonical_target(value), do: canonical_name(value)

  defp record_ttl(rrset) do
    Enum.reduce_while(rrset, {:ok, :unset}, fn entry, {:ok, expected_ttl} ->
      case entry_ttl(entry) do
        {:ok, ttl} when expected_ttl == :unset -> {:cont, {:ok, ttl}}
        {:ok, ttl} when ttl == expected_ttl -> {:cont, {:ok, expected_ttl}}
        _invalid -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, ttl} when is_integer(ttl) -> {:ok, ttl}
      _invalid -> :error
    end
  end

  defp entry_ttl(entry) when is_map(entry) do
    values = ttl_values(entry) ++ nested_ttl_values(entry)

    case values do
      [ttl | rest] ->
        if valid_ttl?(ttl) and Enum.all?(rest, &(valid_ttl?(&1) and &1 === ttl)) do
          {:ok, ttl}
        else
          :error
        end

      [] ->
        :error
    end
  end

  defp entry_ttl(_entry), do: :error

  defp nested_ttl_values(entry) do
    Enum.flat_map([:rdata, "rdata"], fn key ->
      case Map.fetch(entry, key) do
        {:ok, nested} when is_map(nested) -> ttl_values(nested)
        _missing_or_invalid -> []
      end
    end)
  end

  defp ttl_values(map) do
    Enum.flat_map([:ttl, "ttl"], fn key ->
      case Map.fetch(map, key) do
        {:ok, value} -> [value]
        :error -> []
      end
    end)
  end

  defp valid_ttl?(value), do: is_integer(value) and value in 0..2_147_483_647

  defp record_values(type, rrset) do
    Enum.reduce_while(rrset, {:ok, []}, fn entry, {:ok, values} ->
      case record_value(type, entry) do
        {:ok, value} -> {:cont, {:ok, [value | values]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, values |> Enum.uniq() |> Enum.sort()}
      :error -> :error
    end
  end

  defp record_data(%{} = entry), do: field(entry, :rdata, entry)
  defp record_data(entry), do: entry

  defp record_value(type, entry) when type in ["A", "AAAA"] do
    value = record_data(entry)
    value = if is_map(value), do: field(value, :address), else: value

    cond do
      is_binary(value) -> {:ok, value}
      is_tuple(value) -> format_ip(value)
      true -> :error
    end
  end

  defp record_value("CNAME", entry), do: domain_record_value(record_data(entry), :cname)
  defp record_value("NS", entry), do: domain_record_value(record_data(entry), :nsdname)
  defp record_value("PTR", entry), do: domain_record_value(record_data(entry), :ptrdname)

  defp record_value("MX", %{rdata: target} = entry) when is_binary(target) do
    case field(entry, :priority, field(entry, :preference)) do
      priority when is_integer(priority) -> {:ok, "#{priority} #{canonical_name(target)}"}
      _invalid -> :error
    end
  end

  defp record_value("MX", %{"rdata" => target} = entry) when is_binary(target) do
    case field(entry, :priority, field(entry, :preference)) do
      priority when is_integer(priority) -> {:ok, "#{priority} #{canonical_name(target)}"}
      _invalid -> :error
    end
  end

  defp record_value("MX", entry) do
    mx_record_value(record_data(entry))
  end

  defp record_value("SRV", entry), do: srv_record_value(record_data(entry))

  defp record_value("TXT", entry) do
    case record_data(entry) do
      %{} = value -> text_record_value(field(value, :txtdata))
      value -> text_record_value(value)
    end
  end

  defp record_value(_type, _value), do: :error

  defp mx_record_value({priority, target})
       when is_integer(priority) and is_binary(target),
       do: {:ok, "#{priority} #{canonical_name(target)}"}

  defp mx_record_value(%{} = value) do
    with priority when is_integer(priority) <- field(value, :preference, field(value, :priority)),
         target when is_binary(target) <- field(value, :exchange, field(value, :target)) do
      {:ok, "#{priority} #{canonical_name(target)}"}
    else
      _invalid -> :error
    end
  end

  defp mx_record_value(_value), do: :error

  defp srv_record_value({priority, weight, port, target})
       when is_integer(priority) and is_integer(weight) and is_integer(port) and
              is_binary(target),
       do: {:ok, "#{priority} #{weight} #{port} #{canonical_name(target)}"}

  defp srv_record_value(%{} = value) do
    with priority when is_integer(priority) <- field(value, :priority),
         weight when is_integer(weight) <- field(value, :weight),
         port when is_integer(port) <- field(value, :port),
         target when is_binary(target) <- field(value, :target) do
      {:ok, "#{priority} #{weight} #{port} #{canonical_name(target)}"}
    else
      _invalid -> :error
    end
  end

  defp srv_record_value(_value), do: :error

  defp domain_record_value(%{} = value, key), do: domain_record_value(field(value, key), key)

  defp domain_record_value(value, _key) when is_binary(value),
    do: {:ok, canonical_name(value)}

  defp domain_record_value(_value, _key), do: :error

  defp text_record_value(value) when is_binary(value), do: {:ok, value}

  defp text_record_value(value) when is_list(value) do
    if Enum.all?(value, &is_binary/1), do: {:ok, Enum.join(value)}, else: :error
  end

  defp text_record_value(_value), do: :error

  defp format_ip(tuple) do
    case :inet.ntoa(tuple) do
      address when is_list(address) -> {:ok, List.to_string(address)}
      _invalid -> :error
    end
  rescue
    _exception -> :error
  end

  defp validate_record_reference(operation, payload)
       when operation in ["server.dns.records.create", "server.dns.records.update"] do
    with owner when is_binary(owner) <- Map.get(payload, "name"),
         type when is_binary(type) <- Map.get(payload, "type"),
         :ok <- validate_wire_record_type(type),
         requested_id when is_binary(requested_id) <- Map.get(payload, "record_id"),
         true <- valid_record_id?(requested_id),
         true <- requested_id == record_id(canonical_owner(owner), type) do
      :ok
    else
      _invalid -> invalid_error()
    end
  end

  defp validate_record_reference("server.dns.records.delete", %{"record_id" => record_id}) do
    if valid_record_id?(record_id), do: :ok, else: invalid_error()
  end

  defp resolve_record_id(view_name, zone_name, requested_id) do
    if valid_record_id?(requested_id) do
      with {:ok, records} <- read_records(view_name, zone_name) do
        case Enum.filter(records, &(&1["record_id"] == requested_id)) do
          [record] -> {:ok, record}
          [] -> not_found_error()
          [_first | _rest] -> conflict_error()
        end
      end
    else
      invalid_error()
    end
  end

  defp valid_record_id?(record_id) when is_binary(record_id),
    do: Regex.match?(@record_id_pattern, record_id)

  defp valid_record_id?(_record_id), do: false

  defp record_id(owner, type) do
    digest = :crypto.hash(:sha256, canonical_owner(owner) <> <<0>> <> type)
    "rr-" <> Base.encode16(digest, case: :lower)
  end

  defp read_acls do
    with {:ok, acls} <- dependency_call(:acl_registry, :list_acls, []),
         true <- is_list(acls) do
      acls
      |> Enum.reduce_while({:ok, []}, fn acl, {:ok, items} ->
        case project_acl(acl) do
          {:ok, item} -> {:cont, {:ok, [item | items]}}
          {:error, %Error{}} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, items} -> {:ok, Enum.sort_by(items, & &1["acl_id"])}
        {:error, %Error{}} = error -> error
      end
    else
      {:error, %Error{}} = error -> error
      _invalid -> apply_failed_error()
    end
  end

  defp project_acl(%{} = acl) do
    with acl_id when is_binary(acl_id) <- field(acl, :name, field(acl, :acl_id)),
         {:ok, action, networks} <- acl_fields(acl) do
      {:ok, %{"acl_id" => acl_id, "networks" => networks, "action" => action}}
    else
      {:error, %Error{}} = error -> error
      _invalid -> invalid_error()
    end
  end

  defp project_acl(_acl), do: invalid_error()

  defp acl_fields(acl) do
    rules = field(acl, :rules, [])

    cond do
      not is_list(rules) ->
        invalid_error()

      rules != [] ->
        acl_rule_fields(rules)

      true ->
        with {:ok, action} <- wire_acl_action(field(acl, :action, :deny)),
             networks when is_list(networks) <- field(acl, :networks, []),
             {:ok, networks} <- bounded_list(networks, @max_acl_networks),
             {:ok, networks} <- canonical_acl_networks(networks) do
          {:ok, action, networks}
        else
          {:error, %Error{}} = error -> error
          {:error, :too_large} -> unsupported_error()
          _invalid -> invalid_error()
        end
    end
  end

  defp acl_rule_fields(rules) do
    with {:ok, rules} <- bounded_list(rules, @max_acl_networks) do
      rules
      |> Enum.reduce_while({:ok, []}, fn rule, {:ok, entries} ->
        case acl_rule_field(rule) do
          {:ok, entry} -> {:cont, {:ok, [entry | entries]}}
          {:error, %Error{}} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, entries} -> homogeneous_acl_fields(entries)
        {:error, %Error{}} = error -> error
      end
    else
      {:error, :too_large} -> unsupported_error()
    end
  end

  defp acl_rule_field(rule) do
    if is_nil(field(rule, :geo_countries)) do
      case {wire_acl_action(field(rule, :action)), field(rule, :network)} do
        {{:ok, action}, network} when is_binary(network) ->
          with {:ok, network} <- canonical_acl_network(network), do: {:ok, {action, network}}

        _unrepresentable ->
          unsupported_error()
      end
    else
      unsupported_error()
    end
  end

  defp canonical_acl_networks(networks) do
    networks
    |> Enum.reduce_while({:ok, []}, fn network, {:ok, canonical} ->
      case canonical_acl_network(network) do
        {:ok, cidr} -> {:cont, {:ok, [cidr | canonical]}}
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, canonical} -> {:ok, canonical |> Enum.uniq() |> Enum.sort()}
      {:error, %Error{}} = error -> error
    end
  end

  defp canonical_acl_network(network) when is_binary(network) do
    case dependency_call(:acl_codec, :canonical_cidr, [network]) do
      {:ok, {:ok, canonical}} when is_binary(canonical) -> {:ok, canonical}
      {:ok, {:error, :invalid_cidr}} -> invalid_error()
      {:error, %Error{}} = error -> error
      _invalid -> apply_failed_error()
    end
  end

  defp canonical_acl_network(_network), do: invalid_error()

  defp homogeneous_acl_fields(entries) do
    case entries |> Enum.map(&elem(&1, 0)) |> Enum.uniq() do
      [action] ->
        networks = entries |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> Enum.sort()
        {:ok, action, networks}

      _mixed_actions ->
        unsupported_error()
    end
  end

  defp wire_acl_action(:allow), do: {:ok, "allow"}
  defp wire_acl_action("allow"), do: {:ok, "allow"}
  defp wire_acl_action(:deny), do: {:ok, "deny"}
  defp wire_acl_action("deny"), do: {:ok, "deny"}
  defp wire_acl_action(_action), do: :error

  defp read_providers do
    with {:ok, result} <- dependency_call(:provider_store, :list_configs, []),
         {:ok, providers} <- unwrap_store_list(result) do
      items = providers |> Enum.flat_map(&project_provider/1) |> Enum.sort_by(& &1["provider_id"])
      {:ok, items}
    end
  end

  defp project_provider(%{} = provider) do
    with provider_id when is_binary(provider_id) <-
           field(provider, :name, field(provider, :provider_id)),
         {:ok, provider_type} <- wire_provider_type(field(provider, :type)) do
      [
        %{
          "provider_id" => provider_id,
          "provider_type" => provider_type,
          "endpoint" => nil,
          "credential_ref" => credential_ref(provider_id)
        }
      ]
    else
      _invalid -> []
    end
  end

  defp project_provider(_provider), do: []

  defp wire_provider_type(:route53), do: {:ok, "route53"}
  defp wire_provider_type(:aws), do: {:ok, "route53"}
  defp wire_provider_type("route53"), do: {:ok, "route53"}
  defp wire_provider_type("aws"), do: {:ok, "route53"}
  defp wire_provider_type(:cloudflare), do: {:ok, "cloudflare"}
  defp wire_provider_type("cloudflare"), do: {:ok, "cloudflare"}
  defp wire_provider_type(_type), do: :error

  defp credential_ref(provider_id) do
    digest = :crypto.hash(:sha256, provider_id)
    "local-provider-" <> Base.encode16(digest, case: :lower)
  end

  defp read_logs(view_name) do
    with {:ok, logs} <- dependency_call(:query_logger, :control_snapshot, [view_name]),
         true <- is_list(logs) do
      items = logs |> Enum.flat_map(&project_log/1) |> Enum.sort_by(& &1["log_id"])
      {:ok, items}
    else
      {:error, %Error{}} = error -> error
      _invalid -> apply_failed_error()
    end
  end

  defp project_log(%{} = log) do
    with query_name when is_binary(query_name) <- field(log, :qname, field(log, :query_name)),
         {:ok, occurred_at} <- format_datetime(field(log, :timestamp, field(log, :occurred_at))),
         {:ok, action} <- log_action(log) do
      query_name = canonical_name(query_name)

      log_id =
        field(log, :id, field(log, :log_id, generated_log_id(query_name, action, occurred_at)))

      if is_binary(log_id) do
        [
          %{
            "log_id" => log_id,
            "query_name" => query_name,
            "action" => action,
            "occurred_at" => occurred_at
          }
        ]
      else
        []
      end
    else
      _invalid -> []
    end
  end

  defp project_log(_log), do: []

  defp log_action(log) do
    response_code = field(log, :response_code, field(log, :rcode))
    resolution = field(log, :resolution_type)

    cond do
      response_code in [:refused, "refused", "REFUSED"] ->
        {:ok, "refused"}

      response_code in [:noerror, :ok, "noerror", "NOERROR"] and
          resolution in [:recursive, :forward, :forwarded, :fallback, "recursive", "forward"] ->
        {:ok, "forwarded"}

      response_code in [:noerror, :ok, "noerror", "NOERROR"] ->
        {:ok, "answered"}

      true ->
        {:ok, "failed"}
    end
  end

  defp generated_log_id(query_name, action, occurred_at) do
    digest = :crypto.hash(:sha256, query_name <> <<0>> <> action <> <<0>> <> occurred_at)
    "log-" <> Base.encode16(digest, case: :lower)
  end

  defp metrics_result(%{} = metrics) do
    counters = field(metrics, :counters, metrics)
    queries = field(counters, :queries_total, field(metrics, :queries_total, 0))
    responses = field(metrics, :responses_by_code, [])

    if is_integer(queries) and queries >= 0 do
      {:ok, %{"queries" => queries, "failures" => failure_count(responses)}}
    else
      apply_failed_error()
    end
  end

  defp metrics_result(_metrics), do: apply_failed_error()

  defp failure_count(responses) when is_map(responses),
    do: responses |> Map.to_list() |> failure_count()

  defp failure_count(responses) when is_list(responses) do
    Enum.reduce(responses, 0, fn
      {code, count}, total when is_integer(count) and count >= 0 ->
        if code in [:noerror, :ok, "noerror", "NOERROR"], do: total, else: total + count

      _invalid, total ->
        total
    end)
  end

  defp failure_count(_responses), do: 0

  defp list_result(operation_name, items, payload, id_fun) do
    bounded = sort_and_bound(items, id_fun)

    with {:ok, revision} <- Revision.calculate(bounded),
         {:ok, page} <- paginate(bounded, payload, id_fun),
         {:ok, observed_at} <- observation_time() do
      canonical_result = %{
        "items" => bounded,
        "revision" => revision,
        "observed_at" => observed_at
      }

      with {:ok, _canonical_result} <-
             validate_operation_result(operation_name, canonical_result) do
        result = %{canonical_result | "items" => page}
        validate_operation_result(operation_name, result)
      end
    end
  end

  defp validate_current_resource(read_operation, resource) do
    validation_result = %{
      "items" => [resource],
      "revision" => @validation_revision,
      "observed_at" => @validation_observed_at
    }

    case validate_operation_result(read_operation, validation_result) do
      {:ok, _validation_result} -> {:ok, resource}
      {:error, %Error{}} = error -> error
    end
  end

  defp validate_operation_result(operation_name, result) do
    with {:ok, operation} <- ServerOperation.fetch(operation_name),
         {:ok, validated} <- Operation.validate_result(operation, result) do
      {:ok, validated}
    else
      _invalid -> invalid_error()
    end
  end

  defp paginate(items, payload, id_fun) do
    cursor = Map.get(payload, "cursor")
    limit = Map.get(payload, "limit", Bounds.max_list_entries())

    cond do
      not is_integer(limit) or limit < 1 or limit > Bounds.max_list_entries() ->
        invalid_error()

      not is_nil(cursor) and not is_binary(cursor) ->
        invalid_error()

      true ->
        page =
          if cursor do
            Enum.drop_while(items, fn item -> id_fun.(item) <= cursor end)
          else
            items
          end

        {:ok, Enum.take(page, limit)}
    end
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
      _invalid -> :error
    end
  end

  defp format_datetime(_value), do: :error

  defp sort_and_bound(items, id_fun) do
    items
    |> Enum.sort_by(id_fun)
    |> Enum.take(Bounds.max_list_entries())
  end

  defp bounded_list(values, maximum), do: take_bounded(values, maximum, [])

  defp take_bounded([], _remaining, values), do: {:ok, Enum.reverse(values)}
  defp take_bounded([_value | _rest], 0, _values), do: {:error, :too_large}

  defp take_bounded([value | rest], remaining, values),
    do: take_bounded(rest, remaining - 1, [value | values])

  defp unwrap_store_list({:ok, items}) when is_list(items), do: {:ok, items}
  defp unwrap_store_list({:error, :not_found}), do: not_found_error()
  defp unwrap_store_list({:error, _reason}), do: apply_failed_error()
  defp unwrap_store_list(_result), do: apply_failed_error()

  defp dependency_call(key, function, arguments) do
    module = dependency_module(key)
    {:ok, apply(module, function, arguments)}
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

  defp field(map, key, default \\ nil)

  defp field(map, key, default) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key), default)
    end
  end

  defp field(_map, _key, default), do: default

  defp canonical_owner("@"), do: "@"
  defp canonical_owner(owner), do: canonical_name(owner)

  defp canonical_name(name) do
    name
    |> String.downcase()
    |> String.trim_trailing(".")
  end

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
