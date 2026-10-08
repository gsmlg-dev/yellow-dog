defmodule YellowDog.Management.Domain do
  @moduledoc "PostgreSQL-owned Management business operations. No Worker process is involved."

  import Ecto.Query

  alias YellowDog.ConfigSpec

  alias YellowDog.Management.{
    Assignment,
    Backups,
    Audit,
    DnsAcls,
    DnsViews,
    Idempotency,
    Netmans,
    ProfileCatalog,
    Repo,
    ResourceVersion,
    Rrset,
    Service,
    Target,
    Tasks,
    Worker,
    Zone
  }

  @netman_operations ~w(create_netman update_netman update_netman_config confirm_netman_config rollback_netman_config)
  @task_operations ~w(update_task run_task)
  @backup_operations ~w(create_backup delete_backup)
  @dns_acl_operations ~w(create_dns_acl update_dns_acl delete_dns_acl)
  @dns_view_operations ~w(create_dns_view update_dns_view delete_dns_view)
  @operations ~w(create_worker update_worker create_zone update_zone delete_zone confirm_zone put_service assign unassign set_zone_assignments confirm_target) ++
                @netman_operations ++
                @task_operations ++
                @backup_operations ++ @dns_acl_operations ++ @dns_view_operations
  @worker_id ~r/^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/

  @doc "Run an idempotent mutation. All successful effects and the recorded result commit together."
  def mutate(operation, params, actor, idempotency_key)
      when is_binary(operation) and is_map(params) do
    with :ok <- bounded(operation, @operations, "operation"),
         :ok <- bounded(actor, 1..128, "actor"),
         :ok <- bounded(idempotency_key, 1..128, "idempotency_key") do
      params = stringify_keys(params)
      fingerprint = digest({operation, actor, canonical(params)})

      case Repo.transaction(fn ->
             transact(operation, params, actor, idempotency_key, fingerprint)
           end) do
        {:ok, {:ok, result}} ->
          if operation in @task_operations, do: Tasks.broadcast(params["key"])
          if operation in @backup_operations, do: Backups.broadcast(result["id"])
          {:ok, result}

        {:ok, {:error, error}} ->
          {:error, error}

        {:error, error} ->
          {:error, error}
      end
    else
      {:error, error} -> {:error, error}
    end
  rescue
    _error in DBConnection.ConnectionError ->
      {:error,
       error("database_unavailable", "Database unavailable; your submission was not confirmed")}

    error in [Ecto.InvalidChangesetError, Postgrex.Error] ->
      _ = error
      {:error, error("database_constraint", "Database constraint rejected the mutation")}
  end

  def mutate(_, _, _, _),
    do: {:error, error("invalid_request", "Operation and parameters are required")}

  def list_workers do
    Repo.all(from(w in Worker, order_by: w.id))
    |> Enum.map(&worker_map/1)
  end

  defdelegate list_netmans(), to: Netmans, as: :list
  defdelegate get_netman(id), to: Netmans, as: :get
  defdelegate get_netman_config(id), to: Netmans, as: :get_config
  defdelegate list_netman_versions(id), to: Netmans, as: :versions
  defdelegate list_netman_history(), to: Netmans, as: :history
  defdelegate list_tasks(), to: Tasks, as: :list
  defdelegate get_task(key), to: Tasks, as: :get
  defdelegate list_task_jobs(key), to: Tasks, as: :jobs
  defdelegate list_task_history(), to: Tasks, as: :history
  defdelegate list_dns_acls(worker_id, service_id), to: DnsAcls, as: :list
  defdelegate get_dns_acl(worker_id, service_id, id), to: DnsAcls, as: :get
  defdelegate list_dns_views(worker_id, service_id), to: DnsViews, as: :list
  defdelegate get_dns_view(worker_id, service_id, id), to: DnsViews, as: :get

  def list_audit do
    Repo.all(from(a in Audit, order_by: [desc: a.inserted_at, desc: a.id], limit: 100))
    |> Enum.map(fn audit ->
      %{
        "id" => audit.id,
        "actor" => audit.actor,
        "operation" => audit.operation,
        "request" => audit.request,
        "result" => audit.result,
        "inserted_at" => DateTime.to_iso8601(audit.inserted_at)
      }
    end)
  end

  def get_worker(id) do
    Repo.transaction(fn ->
      worker = Repo.one(from(w in Worker, where: w.id == ^id, lock: "FOR SHARE"))
      if worker == nil, do: abort("not_found", "Worker not found")

      worker
      |> worker_map()
      |> Map.put("services", list_services(id))
      |> Map.put("assignments", list_assignments(id))
    end)
  end

  def list_zones do
    Repo.all(from(z in Zone, where: is_nil(z.deleted_at), order_by: z.name, preload: [:rrsets]))
    |> Enum.map(&zone_map/1)
  end

  def get_zone(id) do
    case Ecto.UUID.cast(id) do
      {:ok, _} ->
        case Repo.one(
               from(z in Zone, where: z.id == ^id and is_nil(z.deleted_at), preload: [:rrsets])
             ) do
          nil -> {:error, error("not_found", "Zone not found")}
          zone -> {:ok, zone_map(zone)}
        end

      :error ->
        {:error, error("invalid_request", "Zone ID must be a UUID")}
    end
  end

  def list_versions(zone_id) do
    case Ecto.UUID.cast(zone_id) do
      {:ok, _} ->
        Repo.all(
          from(v in ResourceVersion, where: v.zone_id == ^zone_id, order_by: [asc: v.version])
        )
        |> Enum.map(&version_map/1)

      :error ->
        []
    end
  end

  def list_services(worker_id) do
    Repo.all(from(s in Service, where: s.worker_id == ^worker_id, order_by: s.instance_id))
    |> Enum.map(&service_map/1)
  end

  def list_assignments(worker_id) do
    Repo.all(
      from(a in Assignment,
        join: s in Service,
        on: a.service_id == s.id,
        where: s.worker_id == ^worker_id,
        order_by: [s.instance_id, a.zone_id],
        preload: [:resource_version]
      )
    )
    |> Enum.map(&assignment_map/1)
  end

  @doc "Read the canonical Zone assignment set and its concurrency snapshot."
  def get_zone_assignments(zone_id) do
    Repo.transaction(fn ->
      zone = required_zone(zone_id)
      zone_assignment_snapshot(zone.id)
    end)
  end

  def get_target(worker_id, revision \\ :latest) do
    query = from(t in Target, where: t.worker_id == ^worker_id)

    target =
      case revision do
        :latest ->
          Repo.one(from(t in query, order_by: [desc: t.revision], limit: 1))

        value when is_integer(value) and value > 0 ->
          Repo.one(from(t in query, where: t.revision == ^value))

        _ ->
          nil
      end

    case target do
      nil -> {:error, error("not_found", "Confirmed target not found")}
      target -> {:ok, target_map(target)}
    end
  end

  def list_target_history do
    Repo.all(
      from(target in Target,
        join: worker in Worker,
        on: worker.id == target.worker_id,
        order_by: [desc: target.inserted_at, asc: target.worker_id, desc: target.revision],
        select: %{
          "id" => target.id,
          "worker_id" => target.worker_id,
          "worker_name" => worker.name,
          "revision" => target.revision,
          "digest" => target.digest,
          "prepared_at" => target.inserted_at
        }
      )
    )
    |> Enum.map(fn target ->
      target
      |> Map.update!("prepared_at", &DateTime.to_iso8601/1)
      |> Map.put("status", "prepared")
      |> Map.put("actual_state", "unknown")
    end)
  end

  def preview_target(worker_id) do
    Repo.transaction(fn ->
      worker = lock_worker(worker_id)
      latest = latest_target(worker.id)
      next_revision = if latest, do: latest.revision + 1, else: 1
      plan = build_plan(worker.id, next_revision)

      diff =
        if latest do
          unwrap_spec(ConfigSpec.diff(latest.plan, plan))
        else
          unwrap_spec(ConfigSpec.diff(empty_plan(worker.id), plan))
        end

      %{
        "worker_id" => worker.id,
        "worker_revision" => worker.revision,
        "next_target_revision" => next_revision,
        "plan" => plan,
        "diff" => diff,
        "status" => "prepared_preview",
        "actual_state" => "unknown"
      }
    end)
  end

  defp transact(operation, params, actor, key, fingerprint) do
    Repo.insert!(%Idempotency{key: key, request_digest: fingerprint, result: %{}},
      on_conflict: :nothing
    )

    row = Repo.one!(from(i in Idempotency, where: i.key == ^key, lock: "FOR UPDATE"))

    cond do
      row.request_digest != fingerprint ->
        Repo.rollback(error("idempotency_conflict", "Key was used for a different request"))

      Map.has_key?(row.result, "ok") ->
        {:ok, row.result["ok"]}

      Map.has_key?(row.result, "error") ->
        {:error, public_error(row.result["error"])}

      true ->
        Repo.query!("SAVEPOINT management_dispatch")
        Process.put(:management_dispatch_savepoint, true)

        outcome =
          try do
            {:ok, dispatch(operation, params, actor)}
          rescue
            _error in [Ecto.InvalidChangesetError, Postgrex.Error] ->
              {:error, error("database_constraint", "Database constraint rejected the mutation")}
          catch
            {:management_abort, error} -> {:error, error}
          after
            Process.delete(:management_dispatch_savepoint)
          end

        case outcome do
          {:ok, result} ->
            Repo.query!("RELEASE SAVEPOINT management_dispatch")

            Repo.insert!(%Audit{
              actor: actor,
              operation: operation,
              request: params,
              result: result
            })

            Repo.update_all(from(i in Idempotency, where: i.key == ^key),
              set: [result: %{"ok" => result}]
            )

            {:ok, result}

          {:error, failure} ->
            Repo.query!("ROLLBACK TO SAVEPOINT management_dispatch")
            Repo.query!("RELEASE SAVEPOINT management_dispatch")
            safe_failure = json_safe(failure)

            Repo.insert!(%Audit{
              actor: actor,
              operation: operation,
              request: params,
              result: %{"error" => safe_failure}
            })

            Repo.update_all(from(i in Idempotency, where: i.key == ^key),
              set: [result: %{"error" => safe_failure}]
            )

            {:error, public_error(safe_failure)}
        end
    end
  end

  defp dispatch(operation, params, actor) when operation in @task_operations,
    do: Tasks.dispatch(operation, params, actor)

  defp dispatch(operation, params, _actor), do: dispatch(operation, params)

  defp dispatch(operation, params) when operation in @netman_operations,
    do: Netmans.dispatch(operation, params)

  defp dispatch(operation, params) when operation in @backup_operations,
    do: Backups.dispatch(operation, params)

  defp dispatch(operation, params) when operation in @dns_acl_operations,
    do: DnsAcls.dispatch(operation, params)

  defp dispatch(operation, params) when operation in @dns_view_operations,
    do: DnsViews.dispatch(operation, params)

  defp dispatch("create_worker", params) do
    id = required_string(params, "id", 64)

    if not Regex.match?(@worker_id, id),
      do:
        abort(
          "invalid_worker_id",
          "Worker ID must use letters, digits, dot, underscore, or hyphen"
        )

    name = required_string(params, "name", 128)
    capabilities = capabilities(params)
    if Repo.get(Worker, id), do: abort("conflict", "Worker ID already exists")

    %Worker{
      id: id,
      name: name,
      profile_name: worker_profile(params, "custom"),
      expected_capabilities: capabilities
    }
    |> Repo.insert!()
    |> worker_map()
  end

  defp dispatch("update_worker", params) do
    worker = lock_worker(required_string(params, "id", 64))
    expect_revision(worker.revision, params)

    name =
      if Map.has_key?(params, "name"), do: required_string(params, "name", 128), else: worker.name

    capabilities =
      if Map.has_key?(params, "expected_capabilities"),
        do: capabilities(params),
        else: worker.expected_capabilities

    worker
    |> Ecto.Changeset.change(
      name: name,
      profile_name: worker_profile(params, worker.profile_name),
      expected_capabilities: capabilities,
      revision: worker.revision + 1
    )
    |> Repo.update!()
    |> worker_map()
  end

  defp dispatch("create_zone", params) do
    allowed_keys(params, ~w(name records content))
    id = Ecto.UUID.generate()
    content = zone_content(params)
    resource = normalize_resource(id, 1, content)
    name = resource["content"]["name"]

    if Repo.exists?(from(z in Zone, where: z.name == ^name and is_nil(z.deleted_at))),
      do: abort("conflict", "Active Zone name already exists")

    zone = Repo.insert!(%Zone{id: id, name: name})
    replace_rrsets(zone.id, resource["content"]["records"])
    zone |> Repo.preload(:rrsets) |> zone_map()
  end

  defp dispatch("update_zone", params) do
    allowed_keys(params, ~w(id expected_revision name records content))
    zone = lock_zone(required_string(params, "id", 64))
    expect_revision(zone.revision, params)
    content = zone_content(params)
    resource = normalize_resource(zone.id, 1, content)
    name = resource["content"]["name"]

    if Repo.exists?(
         from(z in Zone, where: z.name == ^name and z.id != ^zone.id and is_nil(z.deleted_at))
       ),
       do: abort("conflict", "Active Zone name already exists")

    zone =
      zone |> Ecto.Changeset.change(name: name, revision: zone.revision + 1) |> Repo.update!()

    replace_rrsets(zone.id, resource["content"]["records"])
    zone |> Repo.preload(:rrsets) |> zone_map()
  end

  defp dispatch("delete_zone", params) do
    zone = lock_zone(required_string(params, "id", 64))
    expect_revision(zone.revision, params)

    if Repo.exists?(from(a in Assignment, where: a.zone_id == ^zone.id)) do
      abort("assigned", "Unassign Zone from all services before deleting it")
    end

    zone =
      zone
      |> Ecto.Changeset.change(deleted_at: DateTime.utc_now(), revision: zone.revision + 1)
      |> Repo.update!()

    %{"id" => zone.id, "revision" => zone.revision, "deleted" => true}
  end

  defp dispatch("confirm_zone", params) do
    zone = lock_zone(required_string(params, "id", 64))
    expect_revision(zone.revision, params)

    case Repo.one(
           from(v in ResourceVersion,
             where: v.zone_id == ^zone.id and v.source_revision == ^zone.revision
           )
         ) do
      nil ->
        zone = Repo.preload(zone, :rrsets)

        number =
          Repo.one(
            from(v in ResourceVersion, where: v.zone_id == ^zone.id, select: max(v.version))
          ) || 0

        resource =
          normalize_resource(zone.id, number + 1, %{
            "name" => zone.name,
            "records" => records(zone)
          })

        %ResourceVersion{
          zone_id: zone.id,
          version: number + 1,
          source_revision: zone.revision,
          content: resource["content"],
          digest: resource["digest"]
        }
        |> Repo.insert!()
        |> version_map()

      version ->
        version_map(version)
    end
  end

  defp dispatch("put_service", params) do
    allowed_keys(params, ~w(worker_id expected_revision id instance_id type desired_state config))
    worker = lock_worker(required_string(params, "worker_id", 64))
    expect_revision(worker.revision, params)
    instance_id = Map.get(params, "instance_id", Map.get(params, "id", "dns"))

    if not (is_binary(instance_id) and Regex.match?(@worker_id, instance_id)),
      do: abort("invalid_service_id", "Service instance ID is invalid")

    type = Map.get(params, "type", "dns")
    state = Map.get(params, "desired_state", "stopped")
    config = stringify_keys(Map.get(params, "config", %{}))
    validate_service(worker.id, instance_id, type, state, config)

    service =
      Repo.one(
        from(s in Service, where: s.worker_id == ^worker.id and s.instance_id == ^instance_id)
      )

    service =
      case service do
        nil ->
          created =
            Repo.insert!(%Service{
              worker_id: worker.id,
              instance_id: instance_id,
              type: type,
              desired_state: state,
              config: config
            })

          if created.type == "dns", do: DnsViews.provision_default(created)
          created

        existing ->
          existing
          |> Ecto.Changeset.change(type: type, desired_state: state, config: config)
          |> Repo.update!()
      end

    build_plan(worker.id, next_target_revision(worker.id))
    bump_worker(worker)
    service |> service_map() |> Map.put("worker_revision", worker.revision + 1)
  end

  defp dispatch("assign", params) do
    version = required_version(required_string(params, "resource_version_id", 64))
    zone = lock_zone(version.zone_id)
    worker = lock_worker(required_string(params, "worker_id", 64))
    expect_revision(worker.revision, params)
    service = required_service(worker.id, params)
    if service.type != "dns", do: abort("unsupported", "DNS Zones require a DNS service")

    existing =
      Repo.one(
        from(a in Assignment, where: a.service_id == ^service.id and a.zone_id == ^zone.id)
      )

    assignment =
      case existing do
        nil ->
          Repo.insert!(%Assignment{
            service_id: service.id,
            zone_id: zone.id,
            resource_version_id: version.id
          })

        current ->
          current |> Ecto.Changeset.change(resource_version_id: version.id) |> Repo.update!()
      end

    build_plan(worker.id, next_target_revision(worker.id))
    bump_worker(worker)

    assignment
    |> Repo.preload(:resource_version)
    |> assignment_map()
    |> Map.put("worker_revision", worker.revision + 1)
  end

  defp dispatch("unassign", params) do
    zone_id =
      case Map.get(params, "zone_id", Map.get(params, "resource_id")) do
        nil -> required_version(required_string(params, "resource_version_id", 64)).zone_id
        value -> value
      end

    lock_zone(zone_id)
    worker = lock_worker(required_string(params, "worker_id", 64))
    expect_revision(worker.revision, params)
    service = required_service(worker.id, params)

    case Repo.one(
           from(a in Assignment, where: a.service_id == ^service.id and a.zone_id == ^zone_id)
         ) do
      nil ->
        abort("not_found", "Assignment not found")

      assignment ->
        Repo.delete!(assignment)
        build_plan(worker.id, next_target_revision(worker.id))
        bump_worker(worker)

        %{
          "id" => assignment.id,
          "worker_id" => worker.id,
          "worker_revision" => worker.revision + 1,
          "removed" => true
        }
    end
  end

  defp dispatch("set_zone_assignments", params) do
    allowed_keys(
      params,
      ~w(zone_id expected_assignment_token expected_worker_revisions assignments)
    )

    zone = lock_zone(required_string(params, "zone_id", 64))
    existing = zone_assignment_rows(zone.id)
    expected_token = required_string(params, "expected_assignment_token", 64)

    if expected_token != assignment_token(zone.id, existing),
      do: abort("revision_conflict", "Assignment set changed; reload before saving assignments")

    submitted = params["assignments"]
    revisions = params["expected_worker_revisions"]

    unless is_list(submitted) and length(submitted) <= 256 and Enum.all?(submitted, &is_map/1),
      do: abort("invalid_request", "assignments must be a list of at most 256 selections")

    unless is_map(revisions),
      do: abort("invalid_request", "expected_worker_revisions must be an object")

    submitted_worker_ids = Enum.map(submitted, &required_string(&1, "worker_id", 64))

    workers =
      (Enum.map(existing, & &1.service.worker_id) ++ submitted_worker_ids)
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map(fn worker_id ->
        worker = lock_worker(worker_id)
        expect_revision(worker.revision, %{"expected_revision" => revisions[worker_id]})
        worker
      end)

    selections =
      Enum.map(submitted, fn selection ->
        allowed_keys(selection, ~w(worker_id service_id resource_version_id))
        required_string(selection, "service_id", 64)
        service = required_service(selection["worker_id"], selection)
        if service.type != "dns", do: abort("unsupported", "DNS Zones require a DNS service")
        version = required_version(required_string(selection, "resource_version_id", 64))

        if version.zone_id != zone.id,
          do: abort("invalid_request", "Confirmed version must belong to the selected Zone")

        {service, version}
      end)

    service_ids = Enum.map(selections, fn {service, _version} -> service.id end)

    if length(Enum.uniq(service_ids)) != length(service_ids),
      do: abort("invalid_request", "Select each DNS Service only once")

    selections
    |> Enum.group_by(fn {service, _version} -> service.worker_id end)
    |> Enum.each(fn {worker_id, values} ->
      versions = Enum.map(values, fn {_service, version} -> version.id end)
      validate_assignment_versions(worker_id, zone.id, versions)
    end)

    existing_by_service = Map.new(existing, &{&1.service_id, &1})

    Enum.each(existing, fn assignment ->
      if assignment.service_id not in service_ids, do: Repo.delete!(assignment)
    end)

    Enum.each(selections, fn {service, version} ->
      case existing_by_service[service.id] do
        nil ->
          Repo.insert!(%Assignment{
            service_id: service.id,
            zone_id: zone.id,
            resource_version_id: version.id
          })

        %{resource_version_id: version_id} when version_id == version.id ->
          :ok

        assignment ->
          assignment
          |> Ecto.Changeset.change(resource_version_id: version.id)
          |> Repo.update!()
      end
    end)

    Enum.each(workers, fn worker ->
      build_plan(worker.id, next_target_revision(worker.id))
      bump_worker(worker)
    end)

    zone_assignment_snapshot(zone.id)
  end

  defp dispatch("confirm_target", params) do
    worker = lock_worker(required_string(params, "worker_id", 64))
    expect_revision(worker.revision, params)
    latest = latest_target(worker.id)
    revision = if latest, do: latest.revision + 1, else: 1
    plan = build_plan(worker.id, revision)

    target =
      Repo.insert!(%Target{
        worker_id: worker.id,
        revision: revision,
        plan: plan,
        digest: plan_digest(plan)
      })

    bump_worker(worker)
    target |> target_map() |> Map.put("worker_revision", worker.revision + 1)
  end

  defp lock_worker(id) do
    case Repo.one(from(w in Worker, where: w.id == ^id, lock: "FOR UPDATE")) do
      nil -> abort("not_found", "Worker not found")
      worker -> worker
    end
  end

  defp lock_zone(id) do
    unless match?({:ok, _}, Ecto.UUID.cast(id)),
      do: abort("invalid_request", "Zone ID must be a UUID")

    case Repo.one(
           from(z in Zone, where: z.id == ^id and is_nil(z.deleted_at), lock: "FOR UPDATE")
         ) do
      nil -> abort("not_found", "Zone not found")
      zone -> zone
    end
  end

  defp required_zone(id) do
    unless match?({:ok, _}, Ecto.UUID.cast(id)),
      do: abort("invalid_request", "Zone ID must be a UUID")

    case Repo.one(from(z in Zone, where: z.id == ^id and is_nil(z.deleted_at), lock: "FOR SHARE")) do
      nil -> abort("not_found", "Zone not found")
      zone -> zone
    end
  end

  defp required_version(id) do
    unless match?({:ok, _}, Ecto.UUID.cast(id)),
      do: abort("invalid_request", "Version ID must be a UUID")

    case Repo.get(ResourceVersion, id) do
      nil -> abort("not_found", "Confirmed Zone version not found")
      version -> version
    end
  end

  defp required_service(worker_id, params) do
    id = Map.get(params, "service_id", "dns")
    unless is_binary(id), do: abort("invalid_request", "service_id must be a string")

    service =
      Repo.one(from(s in Service, where: s.worker_id == ^worker_id and s.instance_id == ^id))

    service =
      if service == nil and match?({:ok, _}, Ecto.UUID.cast(id)) do
        Repo.one(from(s in Service, where: s.worker_id == ^worker_id and s.id == ^id))
      else
        service
      end

    case service do
      nil -> abort("not_found", "Worker service not found")
      service -> service
    end
  end

  defp expect_revision(actual, params) do
    expected = Map.get(params, "expected_revision")

    if expected != actual,
      do:
        abort("revision_conflict", "Expected revision does not match current revision", %{
          "expected" => expected,
          "actual" => actual
        })
  end

  defp bump_worker(worker) do
    worker |> Ecto.Changeset.change(revision: worker.revision + 1) |> Repo.update!()
  end

  defp latest_target(worker_id) do
    Repo.one(
      from(t in Target, where: t.worker_id == ^worker_id, order_by: [desc: t.revision], limit: 1)
    )
  end

  defp next_target_revision(worker_id) do
    case latest_target(worker_id) do
      nil -> 1
      target -> target.revision + 1
    end
  end

  defp build_plan(worker_id, revision) do
    services =
      Repo.all(from(s in Service, where: s.worker_id == ^worker_id, order_by: s.instance_id))

    service_ids = Enum.map(services, & &1.id)

    assignments =
      Repo.all(
        from(a in Assignment, where: a.service_id in ^service_ids, preload: [:resource_version])
      )

    assignments
    |> Enum.group_by(& &1.zone_id)
    |> Enum.each(fn {zone_id, values} ->
      validate_assignment_versions(worker_id, zone_id, Enum.map(values, & &1.resource_version_id))
    end)

    refs = Enum.group_by(assignments, & &1.service_id)

    service_maps =
      Enum.map(services, fn service ->
        %{
          "id" => service.instance_id,
          "type" => service.type,
          "desired_state" => service.desired_state,
          "config" => service.config,
          "resources" => refs |> Map.get(service.id, []) |> Enum.map(& &1.zone_id) |> Enum.sort()
        }
      end)

    resources =
      assignments
      |> Enum.map(& &1.resource_version)
      |> Enum.uniq_by(& &1.id)
      |> Enum.map(&resource_map/1)
      |> Enum.sort_by(&{&1["id"], &1["version"]})

    unwrap_spec(
      ConfigSpec.normalize_plan(%{
        "schema_version" => 1,
        "worker_id" => worker_id,
        "revision" => revision,
        "services" => service_maps,
        "resources" => resources
      })
    )
  end

  defp empty_plan(worker_id) do
    unwrap_spec(
      ConfigSpec.normalize_plan(%{
        "schema_version" => 1,
        "worker_id" => worker_id,
        "revision" => 1,
        "services" => [],
        "resources" => []
      })
    )
  end

  defp validate_service(worker_id, instance_id, type, state, config) do
    unwrap_spec(
      ConfigSpec.normalize_plan(%{
        "schema_version" => 1,
        "worker_id" => worker_id,
        "revision" => 1,
        "services" => [
          %{
            "id" => instance_id,
            "type" => type,
            "desired_state" => state,
            "config" => config,
            "resources" => []
          }
        ],
        "resources" => []
      })
    )
  end

  defp normalize_resource(id, version, content) do
    unwrap_spec(
      ConfigSpec.normalize_resource(%{
        "schema_version" => 1,
        "id" => id,
        "type" => "dns_zone",
        "version" => version,
        "content" => content
      })
    )
  end

  defp zone_content(params) do
    content = Map.get(params, "content")

    content =
      if content == nil do
        Map.take(params, ~w(name records))
      else
        unless Map.keys(params) -- ~w(id expected_revision content) == [],
          do: abort("invalid_request", "Zone fields must be inside content or at the top level")

        content
      end

    unless is_map(content), do: abort("invalid_request", "Zone content must be an object")
    content
  end

  defp allowed_keys(params, keys) do
    case Map.keys(params) -- keys do
      [] -> :ok
      [key | _] -> abort("invalid_request", "Unsupported field: #{key}")
    end
  end

  defp replace_rrsets(zone_id, record_list) do
    Repo.delete_all(from(r in Rrset, where: r.zone_id == ^zone_id))

    record_list
    |> Enum.group_by(&{&1["name"], &1["type"]})
    |> Enum.each(fn {{name, type}, values} ->
      ttls = values |> Enum.map(& &1["ttl"]) |> Enum.uniq()
      if length(ttls) != 1, do: abort("invalid_rrset", "Records in one RRset must share a TTL")

      Repo.insert!(%Rrset{
        zone_id: zone_id,
        name: name,
        type: type,
        ttl: hd(ttls),
        data: Enum.map(values, & &1["data"])
      })
    end)
  end

  defp records(zone) do
    zone.rrsets
    |> Enum.flat_map(fn rrset ->
      Enum.map(rrset.data, fn data ->
        %{"name" => rrset.name, "type" => rrset.type, "ttl" => rrset.ttl, "data" => data}
      end)
    end)
    |> Enum.sort_by(&{&1["name"], &1["type"], &1["ttl"], inspect(&1["data"])})
  end

  defp capabilities(params) do
    value = Map.get(params, "expected_capabilities", [])

    if not (is_list(value) and length(value) <= 16 and Enum.all?(value, &(&1 == "dns")) and
              Enum.uniq(value) == value),
       do: abort("invalid_capabilities", "Only distinct DNS capability entries are supported")

    value
  end

  defp required_string(params, key, max) do
    value = Map.get(params, key)

    if not (is_binary(value) and byte_size(value) in 1..max and String.trim(value) == value and
              not String.contains?(value, <<0>>)),
       do: abort("invalid_request", "#{key} must be a bounded nonempty string")

    value
  end

  defp worker_map(worker) do
    %{
      "id" => worker.id,
      "name" => worker.name,
      "profile_name" => worker.profile_name,
      "expected_capabilities" => worker.expected_capabilities,
      "status" => worker.status,
      "actual_state" => "unknown",
      "revision" => worker.revision
    }
  end

  defp worker_profile(params, current) do
    profile = Map.get(params, "profile_name", current)

    unless Enum.any?(ProfileCatalog.list_server_profiles(), &(to_string(&1.name) == profile)),
      do: abort("invalid_request", "Choose a known Server profile from the catalog")

    profile
  end

  defp zone_map(zone) do
    %{
      "id" => zone.id,
      "name" => zone.name,
      "revision" => zone.revision,
      "records" => records(zone)
    }
  end

  defp version_map(version) do
    %{
      "id" => version.id,
      "resource_id" => version.zone_id,
      "version" => version.version,
      "source_revision" => version.source_revision,
      "content" => version.content,
      "digest" => version.digest
    }
  end

  defp resource_map(version) do
    %{
      "id" => version.zone_id,
      "type" => "dns_zone",
      "schema_version" => 1,
      "version" => version.version,
      "content" => version.content,
      "digest" => version.digest
    }
  end

  defp service_map(service) do
    %{
      "id" => service.id,
      "instance_id" => service.instance_id,
      "worker_id" => service.worker_id,
      "type" => service.type,
      "desired_state" => service.desired_state,
      "config" => service.config,
      "actual_state" => "unknown"
    }
  end

  defp assignment_map(assignment) do
    %{
      "id" => assignment.id,
      "service_id" => assignment.service_id,
      "zone_id" => assignment.zone_id,
      "resource_id" => assignment.zone_id,
      "resource_version_id" => assignment.resource_version_id,
      "version" => assignment.resource_version.version
    }
  end

  defp zone_assignment_rows(zone_id) do
    Repo.all(
      from(a in Assignment,
        join: s in Service,
        on: a.service_id == s.id,
        where: a.zone_id == ^zone_id,
        order_by: [s.worker_id, s.instance_id],
        preload: [:resource_version, service: :worker]
      )
    )
  end

  defp zone_assignment_snapshot(zone_id) do
    rows = zone_assignment_rows(zone_id)

    %{
      "zone_id" => zone_id,
      "assignment_token" => assignment_token(zone_id, rows),
      "worker_revisions" => Repo.all(from(w in Worker, select: {w.id, w.revision})) |> Map.new(),
      "assignments" =>
        Enum.map(rows, fn row ->
          row
          |> assignment_map()
          |> Map.put("worker_id", row.service.worker_id)
          |> Map.put("worker_name", row.service.worker.name)
          |> Map.put("service_instance_id", row.service.instance_id)
        end)
    }
  end

  defp assignment_token(zone_id, rows) do
    snapshot =
      rows
      |> Enum.map(&{&1.id, &1.service_id, &1.resource_version_id, &1.updated_at})
      |> Enum.sort()

    digest({zone_id, snapshot})
  end

  defp validate_assignment_versions(worker_id, zone_id, versions) do
    if length(Enum.uniq(versions)) > 1,
      do:
        abort(
          "invalid_assignment_versions",
          "All DNS Services in one Worker must select the same confirmed Zone version",
          %{"worker_id" => worker_id, "zone_id" => zone_id}
        )
  end

  defp target_map(target) do
    %{
      "id" => target.id,
      "worker_id" => target.worker_id,
      "revision" => target.revision,
      "plan" => target.plan,
      "digest" => target.digest,
      "status" => "prepared",
      "actual_state" => "unknown"
    }
  end

  defp plan_digest(plan), do: unwrap_spec(ConfigSpec.plan_digest(plan))

  defp unwrap_spec({:ok, value}), do: value

  defp unwrap_spec({:error, details}),
    do: abort("invalid_config", "Configuration validation failed", %{"errors" => details})

  defp bounded(value, allowed, field) when is_list(allowed) do
    if value in allowed,
      do: :ok,
      else: {:error, error("invalid_request", "#{field} is unsupported")}
  end

  defp bounded(value, range, field) do
    if is_binary(value) and byte_size(value) in range,
      do: :ok,
      else: {:error, error("invalid_request", "#{field} must be bounded")}
  end

  defp abort(code, message, details \\ %{}) do
    failure = error(code, message, details)

    if Process.get(:management_dispatch_savepoint) do
      throw({:management_abort, failure})
    else
      Repo.rollback(failure)
    end
  end

  defp error(code, message, details \\ %{}), do: %{code: code, message: message, details: details}

  defp stringify_keys(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp canonical(map) when is_map(map),
    do: map |> Enum.map(fn {key, value} -> {key, canonical(value)} end) |> Enum.sort()

  defp canonical(list) when is_list(list), do: Enum.map(list, &canonical/1)
  defp canonical(value), do: value

  defp digest(value),
    do:
      :crypto.hash(:sha256, :erlang.term_to_binary(value, [:deterministic]))
      |> Base.encode16(case: :lower)

  defp json_safe(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), json_safe(value)} end)

  defp json_safe(list) when is_list(list), do: Enum.map(list, &json_safe/1)
  defp json_safe(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp json_safe(value), do: value

  defp public_error(error) do
    %{code: error["code"], message: error["message"], details: error["details"]}
  end
end
