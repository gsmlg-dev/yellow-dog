defmodule YellowDog.Management.DnsViews do
  @moduledoc "Desired DNS Views and their registered Worker assignments."

  import Ecto.Query

  alias YellowDog.Management.{Access, DnsAcls, DnsView, DnsViewWorker, Repo, Service, Worker}

  @editable_keys ~w(priority enabled recursion_enabled ecs_enabled client_rules fallback_forwarders fallback_timeout fallback_retries)
  @scope_keys ~w(worker_id service_id id expected_revision)
  @resource_fields ~w(name priority enabled recursion_enabled client_rules worker_ids)
  @maximum_priority 9_223_372_036_854_775_807
  @default_rules [%{"action" => "allow", "kind" => "any"}]

  def resources do
    Repo.all(
      from(view in DnsView,
        join: assignment in DnsViewWorker,
        on: assignment.view_id == view.id,
        group_by: view.id,
        order_by: [view.name, view.id],
        select:
          {view, fragment("array_agg(? ORDER BY ?)", assignment.worker_id, assignment.worker_id)}
      )
    )
    |> Enum.map(fn {view, worker_ids} -> resource_map(view, worker_ids) end)
  end

  def save_resource(caller, params) do
    mutate_resource(caller, fn ->
      allowed_keys!(params, @resource_fields ++ ~w(id expected_revision))
      worker_ids = worker_ids!(params["worker_ids"])
      name = view_name!(params["name"])

      case params["id"] do
        id when id in [nil, ""] ->
          lock_workers!(worker_ids)

          fields =
            defaults()
            |> Map.merge(%{"recursion_enabled" => false, "client_rules" => []})
            |> Map.merge(Map.take(params, @editable_keys))
            |> fields!(false)

          insert_resource!(name, fields, worker_ids) |> resource_map(worker_ids)

        raw_id ->
          id = uuid!(raw_id, "id")
          previous_workers = assigned_workers(id)
          affected = Enum.sort(Enum.uniq(previous_workers ++ worker_ids))
          lock_workers!(affected)
          view = resource!(id)
          expect_revision!(view, params)

          if assigned_workers(id) != previous_workers,
            do: abort("revision_conflict", "DNS View assignments changed")

          check_names!(name, worker_ids, view.id)

          fields =
            view
            |> view_map(nil)
            |> Map.take(@editable_keys)
            |> Map.merge(Map.take(params, @editable_keys))
            |> fields!(false)

          changed =
            view
            |> Ecto.Changeset.change(
              Map.merge(fields, %{name: name, revision: view.revision + 1})
            )
            |> Repo.update!()

          replace_assignments!(id, worker_ids)
          bump_workers(affected)
          resource_map(changed, worker_ids)
      end
    end)
  end

  def delete_resource(caller, raw_id, revision) do
    mutate_resource(caller, fn ->
      id = uuid!(raw_id, "id")
      workers = assigned_workers(id)
      lock_workers!(workers)
      view = resource!(id)
      expect_revision!(view, %{"expected_revision" => revision})

      if assigned_workers(id) != workers,
        do: abort("revision_conflict", "DNS View assignments changed")

      Repo.delete!(view)
      bump_workers(workers)
      resource_map(view, workers)
    end)
  end

  def has_assignments?(worker_id) do
    Repo.exists?(from(assignment in DnsViewWorker, where: assignment.worker_id == ^worker_id))
  end

  def target_views(worker_id) do
    Repo.all(
      from(view in assigned_views(worker_id),
        where: view.enabled,
        order_by: [view.priority, view.id],
        select: %{
          "id" => view.id,
          "priority" => view.priority,
          "recursion_enabled" => view.recursion_enabled,
          "client_rules" => view.client_rules
        }
      )
    )
  end

  def references(worker_id, limit) do
    Repo.all(
      from(view in assigned_views(worker_id),
        order_by: [view.name, view.id],
        limit: ^limit,
        select: %{
          "id" => view.id,
          "name" => view.name,
          "revision" => view.revision,
          "is_default" => view.is_default
        }
      )
    )
  end

  def list(worker_id, service_id) do
    read(fn ->
      service = scope!(worker_id, service_id)

      Repo.all(
        from(view in scoped_views(service),
          order_by: [asc: view.is_default, asc: view.priority, asc: view.name, asc: view.id]
        )
      )
      |> Enum.map(&view_map(&1, service.worker_id, service.id))
    end)
  end

  def get(worker_id, service_id, id) do
    read(fn ->
      service = scope!(worker_id, service_id)
      view!(service, id) |> view_map(service.worker_id, service.id)
    end)
  end

  def provision_default(%Service{} = service) do
    service = scope!(service.worker_id, service.id, "FOR UPDATE")

    existing =
      Repo.one(
        from(view in DnsView, where: view.service_id == ^service.id and view.name == "default")
      )

    view =
      existing ||
        Repo.insert!(%DnsView{
          service_id: service.id,
          name: "default",
          is_default: true,
          priority: nil
        })

    view_map(view, service.worker_id)
  end

  def dispatch("create_dns_view", params) do
    allowed_keys!(params, ~w(worker_id service_id name) ++ @editable_keys)
    service = scope!(params["worker_id"], params["service_id"], "FOR UPDATE")
    name = view_name!(params["name"])
    fields = fields!(Map.merge(defaults(), Map.take(params, @editable_keys)), false)

    view = insert_resource!(name, fields, [service.worker_id])
    view_map(view, service.worker_id, service.id)
  end

  def dispatch("update_dns_view", params) do
    allowed_keys!(params, @scope_keys ++ @editable_keys)
    service = scope!(params["worker_id"], params["service_id"], "FOR UPDATE")
    view = view!(service, params["id"], "FOR UPDATE")
    expect_revision!(view, params)
    require_single_scope!(view)

    if view.is_default and
         (Map.has_key?(params, "priority") or Map.has_key?(params, "client_rules")),
       do: abort("invalid_request", "Default View priority and client_rules cannot be changed")

    fields =
      view
      |> view_map(service.worker_id)
      |> Map.take(@editable_keys)
      |> Map.merge(Map.take(params, @editable_keys))
      |> fields!(view.is_default)

    changed =
      view
      |> Ecto.Changeset.change(Map.put(fields, :revision, view.revision + 1))
      |> Repo.update!()

    bump_workers([service.worker_id])
    view_map(changed, service.worker_id, service.id)
  end

  def dispatch("delete_dns_view", params) do
    allowed_keys!(params, @scope_keys)
    service = scope!(params["worker_id"], params["service_id"], "FOR UPDATE")
    view = view!(service, params["id"], "FOR UPDATE")
    expect_revision!(view, params)
    if view.is_default, do: abort("conflict", "Default DNS View cannot be deleted")
    require_single_scope!(view)
    Repo.delete!(view)
    bump_workers([service.worker_id])
    view_map(view, service.worker_id, service.id)
  end

  def dispatch(_operation, _params), do: abort("invalid_request", "Unknown DNS View operation")

  defp mutate_resource(caller, callback) do
    with :ok <- Access.authorize(caller, "data:write") do
      Repo.transaction(fn ->
        case read(callback) do
          {:ok, result} -> result
          {:error, error} -> Repo.rollback(error)
        end
      end)
    end
  end

  defp worker_ids!(ids) when is_list(ids) and ids != [] do
    unless Enum.all?(ids, &valid_worker_id?/1),
      do: abort("invalid_request", "Each Worker must be a valid Worker identifier")

    ids |> Enum.uniq() |> Enum.sort()
  end

  defp worker_ids!(_), do: abort("invalid_request", "Select at least one Worker")

  defp lock_workers!(ids) do
    actual =
      Repo.all(
        from(worker in Worker,
          where: worker.id in ^ids,
          order_by: worker.id,
          lock: "FOR UPDATE",
          select: worker.id
        )
      )

    unless Enum.sort(actual) == ids,
      do: abort("not_found", "One or more selected Workers do not exist")
  end

  defp bump_workers(ids) do
    Repo.update_all(from(worker in Worker, where: worker.id in ^ids),
      inc: [revision: 1],
      set: [updated_at: DateTime.utc_now()]
    )
  end

  defp view_name!(name) do
    unless is_binary(name) and String.valid?(name) and
             Regex.match?(~r/\A[A-Za-z0-9_-]{1,63}\z/, name) and name != "default",
           do:
             abort(
               "invalid_request",
               "name must be 1–63 ASCII letters, digits, underscore or hyphen; default is reserved"
             )

    name
  end

  defp insert_resource!(name, fields, worker_ids) do
    check_names!(name, worker_ids, nil)
    view = struct!(DnsView, Map.put(fields, :name, name)) |> Repo.insert!()
    replace_assignments!(view.id, worker_ids)
    bump_workers(worker_ids)
    view
  end

  defp check_names!(name, worker_ids, id) do
    query =
      from(view in DnsView,
        join: assignment in DnsViewWorker,
        on: assignment.view_id == view.id,
        where: view.name == ^name and assignment.worker_id in ^worker_ids
      )

    query = if id, do: from(view in query, where: view.id != ^id), else: query

    if Repo.exists?(query),
      do: abort("conflict", "DNS View name already exists on a selected Worker")
  end

  defp assigned_workers(id) do
    Repo.all(
      from(assignment in DnsViewWorker,
        where: assignment.view_id == ^id,
        order_by: assignment.worker_id,
        select: assignment.worker_id
      )
    )
    |> Enum.sort()
  end

  defp assigned_views(worker_id) do
    from(view in DnsView,
      join: assignment in DnsViewWorker,
      on: assignment.view_id == view.id,
      where: assignment.worker_id == ^worker_id
    )
  end

  defp replace_assignments!(id, worker_ids) do
    Repo.delete_all(from(assignment in DnsViewWorker, where: assignment.view_id == ^id))
    Repo.insert_all(DnsViewWorker, Enum.map(worker_ids, &%{view_id: id, worker_id: &1}))
  end

  defp resource!(id) do
    Repo.one(
      from(view in DnsView, where: view.id == ^id and not view.is_default, lock: "FOR UPDATE")
    ) ||
      abort("not_found", "DNS View not found")
  end

  defp require_single_scope!(view) do
    if match?([_, _ | _], assigned_workers(view.id)),
      do: abort("conflict", "Edit or delete this shared DNS View from Data Management")
  end

  defp defaults do
    %{
      "priority" => 100,
      "enabled" => true,
      "recursion_enabled" => true,
      "ecs_enabled" => false,
      "client_rules" => @default_rules,
      "fallback_forwarders" => [],
      "fallback_timeout" => 2000,
      "fallback_retries" => 1
    }
  end

  defp fields!(candidate, is_default) do
    priority = candidate["priority"]

    unless (is_default and is_nil(priority)) or
             (not is_default and is_integer(priority) and priority >= 0 and
                priority <= @maximum_priority),
           do:
             abort(
               "invalid_request",
               "priority must be a nonnegative bigint; only the default View has null priority"
             )

    for key <- ~w(enabled recursion_enabled ecs_enabled) do
      unless is_boolean(candidate[key]), do: abort("invalid_request", "#{key} must be a boolean")
    end

    rules =
      case DnsAcls.normalize_rules(candidate["client_rules"]) do
        {:ok, rules} -> rules
        {:error, error} -> throw({:management_abort, error})
      end

    if is_default and rules != @default_rules,
      do: abort("invalid_request", "Default View client_rules must allow any client")

    forwarders = candidate["fallback_forwarders"]

    unless is_list(forwarders) and length(forwarders) <= 128,
      do: abort("invalid_request", "fallback_forwarders must be a list of at most 128 endpoints")

    %{
      priority: priority,
      enabled: candidate["enabled"],
      recursion_enabled: candidate["recursion_enabled"],
      ecs_enabled: candidate["ecs_enabled"],
      client_rules: rules,
      fallback_forwarders: Enum.map(forwarders, &forwarder!/1),
      fallback_timeout: integer!(candidate["fallback_timeout"], "fallback_timeout", 100, 30_000),
      fallback_retries: integer!(candidate["fallback_retries"], "fallback_retries", 0, 5)
    }
  end

  defp forwarder!(%{"address" => address, "port" => port} = endpoint) do
    allowed_keys!(endpoint, ~w(address port))
    port = integer!(port, "forwarder port", 1, 65_535)

    with true <- is_binary(address) and byte_size(address) <= 64 and String.valid?(address),
         true <- Regex.match?(~r/\A[0-9A-Fa-f:.]+\z/, address),
         {:ok, ip} <- :inet.parse_strict_address(String.to_charlist(address)) do
      %{"address" => ip |> :inet.ntoa() |> to_string(), "port" => port}
    else
      _invalid -> abort("invalid_request", "Each forwarder address must be an IPv4 or IPv6 IP")
    end
  end

  defp forwarder!(_endpoint),
    do: abort("invalid_request", "Each forwarder must contain address and port")

  defp integer!(value, field, minimum, maximum) do
    unless is_integer(value) and value >= minimum and value <= maximum,
      do: abort("invalid_request", "#{field} must be an integer from #{minimum} to #{maximum}")

    value
  end

  defp read(callback) do
    {:ok, callback.()}
  catch
    {:management_abort, error} -> {:error, error}
  end

  defp scope!(worker_id, service_id, lock \\ nil) do
    unless valid_worker_id?(worker_id),
      do: abort("invalid_request", "worker_id must be a valid Worker identifier")

    service_id = uuid!(service_id, "service_id")

    worker =
      Repo.one(locked(from(worker in Worker, where: worker.id == ^worker_id), lock)) ||
        abort("not_found", "Worker not found")

    service =
      Repo.one(
        locked(
          from(service in Service,
            where: service.id == ^service_id and service.worker_id == ^worker.id
          ),
          lock
        )
      ) ||
        abort("not_found", "DNS Service not found in Worker")

    if service.type != "dns", do: abort("invalid_request", "Service must be a DNS Service")
    service
  end

  defp valid_worker_id?(id) do
    is_binary(id) and String.valid?(id) and
      Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z/, id)
  end

  defp scoped_views(service) do
    from(view in DnsView,
      as: :view,
      where:
        (view.is_default and view.service_id == ^service.id) or
          exists(
            from(assignment in DnsViewWorker,
              where:
                assignment.view_id == parent_as(:view).id and
                  assignment.worker_id == ^service.worker_id
            )
          )
    )
  end

  defp view!(service, id, lock \\ nil) do
    id = uuid!(id, "id")

    Repo.one(
      locked(
        from(view in scoped_views(service), where: view.id == ^id),
        lock
      )
    ) ||
      abort("not_found", "DNS View not found in Service")
  end

  defp locked(query, nil), do: query
  defp locked(query, "FOR UPDATE"), do: from(row in query, lock: "FOR UPDATE")

  defp uuid!(value, field) do
    if is_binary(value) and byte_size(value) == 36 do
      case Ecto.UUID.cast(value) do
        {:ok, id} -> id
        :error -> abort("invalid_request", "#{field} must be a UUID")
      end
    else
      abort("invalid_request", "#{field} must be a UUID")
    end
  end

  defp allowed_keys!(params, keys) do
    unless is_map(params) and Enum.all?(Map.keys(params), &(&1 in keys)),
      do: abort("invalid_request", "Unknown DNS View fields")
  end

  defp expect_revision!(view, params) do
    unless is_integer(params["expected_revision"]) and params["expected_revision"] > 0,
      do: abort("invalid_request", "expected_revision must be a positive integer")

    if params["expected_revision"] != view.revision,
      do: abort("revision_conflict", "Expected revision does not match current DNS View revision")
  end

  defp resource_map(view, worker_ids) do
    view
    |> view_map(nil)
    |> Map.take(@resource_fields ++ ~w(id revision inserted_at updated_at))
    |> Map.put("worker_ids", Enum.sort(worker_ids))
  end

  defp view_map(view, worker_id, service_id \\ nil) do
    %{
      "id" => view.id,
      "worker_id" => worker_id,
      "service_id" => service_id || view.service_id,
      "name" => view.name,
      "is_default" => view.is_default,
      "priority" => view.priority,
      "enabled" => view.enabled,
      "recursion_enabled" => view.recursion_enabled,
      "ecs_enabled" => view.ecs_enabled,
      "client_rules" => view.client_rules,
      "fallback_forwarders" => view.fallback_forwarders,
      "fallback_timeout" => view.fallback_timeout,
      "fallback_retries" => view.fallback_retries,
      "revision" => view.revision,
      "inserted_at" => DateTime.to_iso8601(view.inserted_at),
      "updated_at" => DateTime.to_iso8601(view.updated_at)
    }
  end

  defp abort(code, message),
    do: throw({:management_abort, %{code: code, message: message, details: %{}}})
end
