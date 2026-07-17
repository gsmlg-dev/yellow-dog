defmodule YellowDog.Server.Control.Netboot do
  @moduledoc false

  alias YellowDog.Server.Control.Revision
  alias YellowDog.Sync.Bounds
  alias YellowDog.Sync.Codec
  alias YellowDog.Sync.Error
  alias YellowDog.Sync.Operation
  alias YellowDog.Sync.ServerOperation

  @validation_observed_at "1970-01-01T00:00:00Z"
  @validation_revision String.duplicate("0", 64)
  @unsupported_operations [
    "server.netboot.assets.upload",
    "server.netboot.assets.delete",
    "server.netboot.transfers.list",
    "server.netboot.logs.list"
  ]
  @production_dependencies %{
    manifest_store: Module.concat(["YellowDog", "Netboot", "Manifest", "Store"]),
    managed_profile: Module.concat(["YellowDog", "Netboot", "Manifest", "ManagedProfile"]),
    device_registry: Module.concat(["YellowDog", "Netboot", "Device", "Registry"]),
    asset_store: Module.concat(["YellowDog", "Netboot", "Asset", "Store"]),
    file_index: Module.concat(["YellowDog", "Netboot", "TFTP", "FileIndex"]),
    clock: DateTime
  }
  @test_environment Mix.env() == :test

  @spec dispatch(String.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def dispatch("server.netboot.profiles.list", payload), do: list_profiles(payload)
  def dispatch("server.netboot.devices.list", payload), do: list_devices(payload)
  def dispatch("server.netboot.assets.list", payload), do: list_assets(payload)

  def dispatch(operation, payload) when operation in @unsupported_operations,
    do: unsupported(operation, payload)

  def dispatch("server.netboot.profiles.put", payload), do: put_profile(payload)
  def dispatch("server.netboot.profiles.delete", payload), do: delete_profile(payload)
  def dispatch("server.netboot.devices.put", payload), do: put_device(payload)
  def dispatch("server.netboot.devices.delete", payload), do: delete_device(payload)
  def dispatch("server.netboot.assets.rescan", payload), do: rescan_assets(payload)
  def dispatch(_operation, _payload), do: unsupported_error()

  @spec current(String.t(), map()) :: {:ok, map() | :missing} | {:error, Error.t()}
  def current("server.netboot.profiles.put" = operation, payload) do
    with {:ok, payload} <- validate_payload(operation, payload),
         {:ok, profiles} <- managed_profiles() do
      case find_resource(profiles, "profile_id", payload["profile_id"]) do
        nil -> {:ok, :missing}
        profile -> {:ok, profile}
      end
    end
  end

  def current("server.netboot.profiles.delete" = operation, payload) do
    with {:ok, payload} <- validate_payload(operation, payload),
         {:ok, profiles} <- managed_profiles(),
         profile when not is_nil(profile) <-
           find_resource(profiles, "profile_id", payload["profile_id"]) do
      {:ok, profile}
    else
      nil -> not_found_error()
      {:error, %Error{}} = error -> error
    end
  end

  def current("server.netboot.devices.put" = operation, payload) do
    with {:ok, payload} <- validate_payload(operation, payload),
         {:ok, devices} <- device_resources() do
      case find_resource(devices, "device_id", payload["device_id"]) do
        nil -> {:ok, :missing}
        device -> {:ok, device}
      end
    end
  end

  def current("server.netboot.devices.delete" = operation, payload) do
    with {:ok, payload} <- validate_payload(operation, payload),
         {:ok, devices} <- device_resources(),
         device when not is_nil(device) <-
           find_resource(devices, "device_id", payload["device_id"]) do
      {:ok, device}
    else
      nil -> not_found_error()
      {:error, %Error{}} = error -> error
    end
  end

  def current("server.netboot.assets.rescan" = operation, payload) do
    with {:ok, _payload} <- validate_payload(operation, payload),
         {:ok, snapshot} <- file_index_resources() do
      {:ok, snapshot}
    end
  end

  def current(operation, payload)
      when operation in ["server.netboot.assets.upload", "server.netboot.assets.delete"],
      do: unsupported(operation, payload)

  def current(_operation, _payload), do: unsupported_error()

  defp list_profiles(payload) do
    with {:ok, payload} <- validate_payload("server.netboot.profiles.list", payload),
         {:ok, profiles} <- managed_profiles() do
      list_result(
        "server.netboot.profiles.list",
        profiles,
        payload,
        & &1["profile_id"]
      )
    end
  end

  defp list_devices(payload) do
    with {:ok, payload} <- validate_payload("server.netboot.devices.list", payload),
         {:ok, devices} <- device_resources() do
      list_result(
        "server.netboot.devices.list",
        devices,
        payload,
        & &1["device_id"]
      )
    end
  end

  defp list_assets(payload) do
    with {:ok, payload} <- validate_payload("server.netboot.assets.list", payload),
         {:ok, assets} <- asset_resources() do
      list_result(
        "server.netboot.assets.list",
        assets,
        payload,
        & &1["asset_id"]
      )
    end
  end

  defp put_profile(payload) do
    operation = "server.netboot.profiles.put"

    with {:ok, payload} <- validate_payload(operation, payload),
         {:ok, profile} <- managed_profile_from_wire(payload),
         {:ok, current_snapshot} <- profile_mutation(:put_managed_profile, [profile]),
         {:ok, profiles} <- project_managed_snapshot(current_snapshot),
         resource when not is_nil(resource) <-
           find_resource(profiles, "profile_id", payload["profile_id"]) do
      revisioned_result(operation, "netboot_profile", resource, "profile_id")
    else
      nil -> apply_failed_error()
      {:error, %Error{}} = error -> error
    end
  end

  defp delete_profile(payload) do
    operation = "server.netboot.profiles.delete"

    with {:ok, payload} <- validate_payload(operation, payload),
         {:ok, current_profiles} <- managed_profiles(),
         resource when not is_nil(resource) <-
           find_resource(current_profiles, "profile_id", payload["profile_id"]),
         {:ok, current_snapshot} <-
           profile_mutation(:delete_managed_profile, [payload["profile_id"]]),
         {:ok, resulting_profiles} <- project_managed_snapshot(current_snapshot),
         nil <- find_resource(resulting_profiles, "profile_id", payload["profile_id"]) do
      deleted_result(operation, "netboot_profile", payload, "profile_id")
    else
      nil -> not_found_error()
      %{} -> apply_failed_error()
      {:error, %Error{}} = error -> error
    end
  end

  defp put_device(payload) do
    operation = "server.netboot.devices.put"

    with {:ok, payload} <- validate_payload(operation, payload),
         {:ok, resulting} <-
           device_mutation(:control_put_device, [
             payload["device_id"],
             payload["profile_id"],
             payload["mac"]
           ]),
         {:ok, devices} <- project_devices(resulting),
         resource when not is_nil(resource) <-
           find_resource(devices, "device_id", payload["device_id"]) do
      revisioned_result(operation, "netboot_device", resource, "device_id")
    else
      nil -> apply_failed_error()
      {:error, %Error{}} = error -> error
    end
  end

  defp delete_device(payload) do
    operation = "server.netboot.devices.delete"

    with {:ok, payload} <- validate_payload(operation, payload),
         {:ok, {prior, resulting}} <-
           device_mutation_snapshots(:control_delete_device, [payload["device_id"]]),
         {:ok, prior_devices} <- project_devices(prior),
         resource when not is_nil(resource) <-
           find_resource(prior_devices, "device_id", payload["device_id"]),
         {:ok, resulting_devices} <- project_devices(resulting),
         nil <- find_resource(resulting_devices, "device_id", payload["device_id"]) do
      deleted_result(operation, "netboot_device", payload, "device_id")
    else
      nil -> not_found_error()
      %{} -> apply_failed_error()
      {:error, %Error{}} = error -> error
    end
  end

  defp rescan_assets(payload) do
    operation = "server.netboot.assets.rescan"

    with {:ok, payload} <- validate_payload(operation, payload),
         {:ok, result} <- dependency_call(:asset_store, :control_rescan, [payload["scope"]]),
         {:ok, count} <- rescan_count(result),
         result = %{"scope" => payload["scope"], "discovered_assets" => count},
         {:ok, result} <- validate_result(operation, result) do
      {:ok, result}
    end
  end

  defp unsupported(operation, payload) do
    with {:ok, _payload} <- validate_payload(operation, payload) do
      unsupported_error()
    end
  end

  defp managed_profiles do
    with {:ok, result} <- dependency_call(:manifest_store, :managed_snapshot, []),
         {:ok, snapshot} <- owner_snapshot(result),
         {:ok, profiles} <- project_managed_snapshot(snapshot) do
      {:ok, profiles}
    end
  end

  defp project_managed_snapshot(%{"version" => 1, "profiles" => profiles})
       when is_list(profiles) do
    profiles
    |> Enum.reduce_while({:ok, []}, fn wire, {:ok, resources} ->
      with {:ok, profile} <- managed_profile_from_wire(wire),
           {:ok, resource} <- dependency_call(:managed_profile, :to_wire, [profile]),
           {:ok, resource} <- validate_list_item("server.netboot.profiles.list", resource) do
        {:cont, {:ok, [resource | resources]}}
      else
        {:error, %Error{}} = error -> {:halt, error}
        _other -> {:halt, invalid_error()}
      end
    end)
    |> case do
      {:ok, resources} -> {:ok, Enum.sort_by(resources, & &1["profile_id"])}
      {:error, %Error{}} = error -> error
    end
  end

  defp project_managed_snapshot(_snapshot), do: invalid_error()

  defp managed_profile_from_wire(wire) do
    if runtime_profile_fallback?(wire) do
      apply_failed_error()
    else
      case dependency_call(:managed_profile, :from_wire, [wire]) do
        {:ok, {:ok, profile}} -> {:ok, profile}
        {:ok, {:error, reason}} -> owner_error(reason)
        {:ok, _result} -> invalid_error()
        {:error, %Error{}} = error -> error
      end
    end
  end

  defp profile_mutation(function, arguments) do
    case dependency_call(:manifest_store, function, arguments) do
      {:ok, {:ok, %{previous: previous, current: current}}} ->
        with {:ok, _profiles} <- project_managed_snapshot(previous),
             {:ok, _profiles} <- project_managed_snapshot(current) do
          {:ok, current}
        end

      {:ok, {:error, reason}} ->
        owner_error(reason)

      {:ok, _result} ->
        apply_failed_error()

      {:error, %Error{}} = error ->
        error
    end
  end

  defp device_resources do
    with {:ok, result} <- dependency_call(:device_registry, :control_snapshot, []),
         {:ok, devices} <- owner_list(result),
         {:ok, resources} <- project_devices(devices) do
      {:ok, resources}
    end
  end

  defp project_devices(devices) when is_list(devices) do
    devices
    |> Enum.reduce_while({:ok, []}, fn device, {:ok, resources} ->
      case project_device(device) do
        :skip -> {:cont, {:ok, resources}}
        {:ok, resource} -> {:cont, {:ok, [resource | resources]}}
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, resources} -> {:ok, Enum.sort_by(resources, & &1["device_id"])}
      {:error, %Error{}} = error -> error
    end
  end

  defp project_devices(_devices), do: invalid_error()

  defp project_device(device) when is_map(device) do
    case field(device, :uuid) do
      nil ->
        :skip

      "" ->
        :skip

      device_id ->
        resource = %{
          "device_id" => device_id,
          "profile_id" => field(device, :profile_id),
          "mac" => field(device, :mac)
        }

        validate_list_item("server.netboot.devices.list", resource)
    end
  end

  defp project_device(_device), do: invalid_error()

  defp device_mutation(function, arguments) do
    with {:ok, {_prior, resulting}} <- device_mutation_snapshots(function, arguments) do
      {:ok, resulting}
    end
  end

  defp device_mutation_snapshots(function, arguments) do
    case dependency_call(:device_registry, function, arguments) do
      {:ok, {:ok, prior, resulting}} when is_list(prior) and is_list(resulting) ->
        {:ok, {prior, resulting}}

      {:ok, {:ok, _prior, _resulting}} ->
        invalid_error()

      {:ok, {:error, reason}} ->
        owner_error(reason)

      {:ok, _result} ->
        apply_failed_error()

      {:error, %Error{}} = error ->
        error
    end
  end

  defp asset_resources do
    with {:ok, result} <- dependency_call(:asset_store, :control_snapshot, []),
         {:ok, assets} <- owner_list(result) do
      assets
      |> Enum.reduce_while({:ok, []}, fn asset, {:ok, resources} ->
        case validate_list_item("server.netboot.assets.list", asset) do
          {:ok, resource} -> {:cont, {:ok, [resource | resources]}}
          {:error, %Error{}} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, resources} -> {:ok, Enum.sort_by(resources, & &1["asset_id"])}
        {:error, %Error{}} = error -> error
      end
    end
  end

  defp file_index_resources do
    with {:ok, snapshot} <- dependency_call(:file_index, :snapshot, []),
         true <- is_list(snapshot) do
      snapshot
      |> Enum.reduce_while({:ok, []}, fn entry, {:ok, resources} ->
        case project_file_index_entry(entry) do
          {:ok, resource} -> {:cont, {:ok, [resource | resources]}}
          {:error, %Error{}} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, resources} ->
          resources
          |> Enum.sort_by(& &1["filename"])
          |> complete_file_index_resource()

        {:error, %Error{}} = error ->
          error
      end
    else
      false -> invalid_error()
      {:error, %Error{}} = error -> error
    end
  end

  defp project_file_index_entry({filename, path, size})
       when is_binary(path) and is_integer(size) and size >= 0 do
    validation = %{
      "asset_id" => "file-index-entry",
      "filename" => filename,
      "size" => size,
      "blob_digest" => @validation_revision
    }

    with {:ok, _payload} <- validate_payload("server.netboot.assets.upload", validation) do
      {:ok, %{"filename" => filename, "size" => size}}
    end
  end

  defp project_file_index_entry(_entry), do: invalid_error()

  defp complete_file_index_resource(resources) do
    with {:ok, digest} <- complete_entries_digest(resources) do
      {:ok,
       %{
         "entry_count" => length(resources),
         "entries_digest" => digest
       }}
    end
  end

  defp complete_entries_digest(entries) do
    context =
      :sha256
      |> :crypto.hash_init()
      |> :crypto.hash_update("[")

    entries
    |> Enum.reduce_while({:ok, context, true}, fn entry, {:ok, context, first?} ->
      case Codec.encode(entry) do
        {:ok, encoded} ->
          separator = if first?, do: "", else: ","

          context =
            context
            |> :crypto.hash_update(separator)
            |> :crypto.hash_update(encoded)

          {:cont, {:ok, context, false}}

        {:error, %Error{}} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, context, _first?} ->
        digest =
          context
          |> :crypto.hash_update("]")
          |> :crypto.hash_final()
          |> Base.encode16(case: :lower)

        {:ok, digest}

      {:error, %Error{}} = error ->
        error
    end
  end

  defp rescan_count({:ok, count}) when is_integer(count) and count >= 0, do: {:ok, count}
  defp rescan_count({:ok, _count}), do: invalid_error()
  defp rescan_count({:error, reason}), do: owner_error(reason)
  defp rescan_count(_result), do: apply_failed_error()

  defp list_result(operation, items, payload, id_fun) do
    bounded =
      items
      |> Enum.sort_by(id_fun)
      |> Enum.take(Bounds.max_list_entries())

    with {:ok, revision} <- Revision.calculate(bounded),
         {:ok, page} <- paginate(bounded, payload, id_fun),
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

  defp paginate(items, payload, id_fun) do
    cursor = Map.get(payload, "cursor")
    limit = Map.get(payload, "limit", 100)
    page = if cursor, do: Enum.drop_while(items, &(id_fun.(&1) <= cursor)), else: items
    {:ok, Enum.take(page, limit)}
  end

  defp revisioned_result(operation, resource_type, resource, id_key) do
    with {:ok, revision} <- Revision.calculate(resource),
         result = %{
           "resource_type" => resource_type,
           "resource_id" => resource[id_key],
           "revision" => revision,
           "resource" => resource
         },
         {:ok, result} <- validate_result(operation, result) do
      {:ok, result}
    end
  end

  defp deleted_result(operation, resource_type, resource_ref, id_key) do
    with {:ok, revision} <- Revision.calculate(resource_ref),
         result = %{
           "resource_type" => resource_type,
           "resource_id" => resource_ref[id_key],
           "revision" => revision,
           "resource_ref" => resource_ref
         },
         {:ok, result} <- validate_result(operation, result) do
      {:ok, result}
    end
  end

  defp validate_list_item(operation, item) do
    validation = %{
      "items" => [item],
      "revision" => @validation_revision,
      "observed_at" => @validation_observed_at
    }

    case validate_result(operation, validation) do
      {:ok, %{"items" => [item]}} -> {:ok, item}
      {:error, %Error{}} = error -> error
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
      _other -> apply_failed_error()
    end
  end

  defp format_datetime(_value), do: apply_failed_error()

  defp validate_payload(operation_name, payload) do
    with {:ok, operation} <- ServerOperation.fetch(operation_name),
         {:ok, payload} <- Operation.validate_payload(operation, payload) do
      {:ok, payload}
    else
      _other -> invalid_error()
    end
  end

  defp validate_result(operation_name, result) do
    with {:ok, operation} <- ServerOperation.fetch(operation_name),
         {:ok, result} <- Operation.validate_result(operation, result) do
      {:ok, result}
    else
      _other -> invalid_error()
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
      {:error, _reason} -> apply_failed_error()
      _other -> apply_failed_error()
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

  defp owner_snapshot({:ok, snapshot}) when is_map(snapshot), do: {:ok, snapshot}
  defp owner_snapshot({:ok, _snapshot}), do: invalid_error()
  defp owner_snapshot({:error, reason}), do: owner_error(reason)
  defp owner_snapshot(_result), do: apply_failed_error()

  defp owner_list({:ok, resources}) when is_list(resources), do: {:ok, resources}
  defp owner_list({:ok, _resources}), do: invalid_error()
  defp owner_list({:error, reason}), do: owner_error(reason)
  defp owner_list(_result), do: apply_failed_error()

  defp owner_error(reason)
       when reason in [
              :not_found,
              :noproc,
              :owner_absent,
              :registry_absent,
              :store_absent,
              :manifest_store_absent,
              :asset_store_absent
            ],
       do: not_found_error()

  defp owner_error({:noproc, _details}), do: not_found_error()

  defp owner_error(reason)
       when reason in [
              :conflict,
              :already_exists,
              :duplicate_profile_id,
              :duplicate_device_id,
              :duplicate_uuid,
              :duplicate_mac,
              :duplicate_filename
            ],
       do: conflict_error()

  defp owner_error(reason)
       when reason in [
              :invalid,
              :invalid_arguments,
              :invalid_profile,
              :invalid_snapshot,
              :invalid_asset,
              :invalid_device,
              :invalid_filename
            ],
       do: invalid_error()

  defp owner_error({:persist_failed, _reason}), do: apply_failed_error()
  defp owner_error({:activation_failed, _reason}), do: apply_failed_error()
  defp owner_error({:rollback_failed, _reason, _rollback}), do: rollback_failed_error()

  defp owner_error(reason)
       when reason in [
              :persistence_failed,
              :activation_failed,
              :index_failed,
              :apply_failed
            ],
       do: apply_failed_error()

  defp owner_error(:rollback_failed), do: rollback_failed_error()
  defp owner_error(_reason), do: apply_failed_error()

  defp find_resource(resources, id_key, id),
    do: Enum.find(resources, &(&1[id_key] == id))

  defp runtime_profile_fallback?(profile) when is_map(profile) do
    not is_nil(field(profile, :id)) and
      (not is_nil(field(profile, :kernel)) or
         not is_nil(field(profile, :initrd)) or
         not is_nil(field(profile, :kernel_args)))
  end

  defp runtime_profile_fallback?(_profile), do: false

  defp field(map, key) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
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
