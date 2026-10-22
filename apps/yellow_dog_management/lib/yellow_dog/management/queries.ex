defmodule YellowDog.Management.Queries do
  @moduledoc "Bounded SQL projections for authorized Management callers; never reads artifact bytes."
  import Ecto.Query

  alias YellowDog.Management.{
    Assignment,
    Audit,
    ConfigCompiler,
    Database,
    DnsAcl,
    DnsAcls,
    DnsView,
    DnsViews,
    Domain,
    GeoIPArtifact,
    GeoIPSelection,
    Repo,
    ResourceVersion,
    Service,
    Target,
    TaskDefinition,
    Worker,
    Zone,
    ZoneCatalog
  }

  @worker_fields ~w(id name profile_name expected_capabilities revision last_seen_at applied_revision applied_digest)a
  @service_fields ~w(id worker_id instance_id type desired_state config)a
  @version_fields ~w(id zone_id version source_revision digest)a
  @task_fields ~w(key label enabled cron revision)a

  def run(id, params) do
    case Database.read(fn -> dispatch(id, params) end) do
      {:ok, {:ok, _} = result} -> result
      {:ok, {:error, _} = result} -> result
      {:ok, result} -> {:ok, result}
      {:error, _} = result -> result
    end
  catch
    {:query_error, error} -> {:error, error}
  end

  def export_scope,
    do: %{"scope" => "dns_zones", "excluded" => ~w(dns_views dns_acls geoip_artifacts)}

  def worker_projection(row) do
    row = json(row)
    seen = row["last_seen_at"]

    connected =
      if seen do
        {:ok, date, _} = DateTime.from_iso8601(seen)
        if DateTime.diff(DateTime.utc_now(), date, :second) < 45, do: "connected", else: "offline"
      else
        "not_yet_connected"
      end

    Map.take(
      row,
      ~w(id name profile_name expected_capabilities revision last_seen_at applied_revision applied_digest)
    )
    |> Map.merge(%{"actual_state" => "unknown", "connection_status" => connected})
  end

  def job_projection(row) do
    row
    |> json()
    |> Map.take(
      ~w(id task_key state attempt max_attempts inserted_at attempted_at completed_at discarded_at scheduled_at)
    )
    |> Map.put("verification", "unknown")
  end

  defp dispatch("worker_list", p),
    do:
      paged(
        from(w in Worker, order_by: w.id, select: map(w, @worker_fields)),
        p,
        &worker_projection/1
      )

  defp dispatch("worker_get", p), do: worker!(p["worker_id"]) |> worker_projection()

  defp dispatch("service_list", p) do
    worker!(p["worker_id"])

    paged(
      from(s in Service,
        where: s.worker_id == ^p["worker_id"],
        order_by: [s.instance_id, s.id],
        select: map(s, @service_fields)
      ),
      p,
      &service_projection/1
    )
  end

  defp dispatch("service_get", p), do: scoped_service!(p) |> service_projection()

  defp dispatch("service_references", p) do
    service = scoped_service!(p)

    zones =
      from(a in Assignment,
        join: v in ResourceVersion,
        on: v.id == a.resource_version_id,
        where: a.service_id == ^service.id,
        order_by: [v.zone_id, a.id],
        select: %{
          "id" => a.id,
          "zone_id" => v.zone_id,
          "name" => fragment("?->>'name'", v.content),
          "resource_version_id" => v.id,
          "version" => v.version,
          "digest" => v.digest
        }
      )

    views =
      from(v in DnsView,
        where: v.service_id == ^service.id,
        order_by: [v.name, v.id],
        select: %{
          "id" => v.id,
          "name" => v.name,
          "revision" => v.revision,
          "is_default" => v.is_default
        }
      )

    acls =
      from(a in DnsAcl,
        where: a.service_id == ^service.id,
        order_by: [a.name, a.id],
        select: %{"id" => a.id, "name" => a.name, "revision" => a.revision}
      )

    %{"zones" => paged(zones, p), "views" => paged(views, p), "acls" => paged(acls, p)}
  end

  defp dispatch("zone_list", p) do
    result = ZoneCatalog.list(p)

    %{
      "items" => result["zones"],
      "page" => result["page"],
      "page_size" => result["page_size"],
      "has_next" => result["has_next"]
    }
  end

  defp dispatch("zone_get", p), do: Domain.get_zone(p["id"])

  defp dispatch("zone_versions", p) do
    zone!(p["zone_id"])

    paged(
      from(v in ResourceVersion,
        where: v.zone_id == ^p["zone_id"],
        order_by: [desc: v.version, asc: v.id],
        select: map(v, @version_fields)
      ),
      p,
      &version_projection/1
    )
  end

  defp dispatch("zone_version_get", p) do
    zone!(p["zone_id"])

    Repo.one(
      from(v in ResourceVersion,
        where: v.zone_id == ^p["zone_id"] and v.id == ^p["version_id"],
        select: map(v, ^(@version_fields ++ [:content]))
      )
    )
    |> required!()
    |> version_projection()
  end

  defp dispatch("zone_assignments", p), do: Domain.get_zone_assignments(p["zone_id"], :selected)

  defp dispatch("dns_view_list", p) do
    service = scoped_service!(p)

    paged(
      from(v in DnsView,
        where: v.service_id == ^service.id,
        order_by: [desc: v.is_default, asc: v.priority, asc: v.name, asc: v.id],
        select: map(v, ~w(id name revision is_default enabled priority)a)
      ),
      p
    )
  end

  defp dispatch("dns_acl_list", p) do
    service = scoped_service!(p)

    paged(
      from(a in DnsAcl,
        where: a.service_id == ^service.id,
        order_by: [a.name, a.id],
        select: map(a, ~w(id name revision description)a)
      ),
      p
    )
  end

  defp dispatch("dns_view_get", p), do: DnsViews.get(p["worker_id"], p["service_id"], p["id"])
  defp dispatch("dns_acl_get", p), do: DnsAcls.get(p["worker_id"], p["service_id"], p["id"])

  defp dispatch("worker_target_preview", p) do
    with {:ok, result} <- Domain.preview_target(p["worker_id"]),
         do: {:ok, Map.put(result, "export_scope", export_scope())}
  end

  defp dispatch("worker_target_history", p) do
    worker!(p["worker_id"])

    paged(
      from(t in Target,
        where: t.worker_id == ^p["worker_id"],
        order_by: [desc: t.revision],
        select: %{
          "id" => t.id,
          "worker_id" => t.worker_id,
          "revision" => t.revision,
          "digest" => t.digest,
          "prepared_at" => t.inserted_at
        }
      ),
      p,
      &(json(&1) |> Map.merge(%{"status" => "prepared", "actual_state" => "unknown"}))
    )
  end

  defp dispatch("worker_target_get", p) do
    with {:ok, result} <- Domain.get_target(p["worker_id"], p["revision"]),
         do: {:ok, Map.put(result, "export_scope", export_scope())}
  end

  defp dispatch("worker_target_export", p) do
    with {:ok, result} <- ConfigCompiler.export_target(p["worker_id"], p["revision"]),
         do: {:ok, Map.put(result, "export_scope", export_scope())}
  end

  defp dispatch("task_list", p),
    do:
      paged(
        from(t in TaskDefinition,
          where: t.key in ["ip_city", "ip_country"],
          order_by: t.key,
          select: map(t, @task_fields)
        ),
        p
      )

  defp dispatch("task_get", p),
    do:
      Repo.one(from(t in TaskDefinition, where: t.key == ^p["key"], select: map(t, @task_fields)))
      |> required!()
      |> json()

  defp dispatch("task_jobs", p) do
    query = jobs_query()

    query =
      if p["key"],
        do: from(j in query, where: fragment("?->>'task_key' = ?", j.args, ^p["key"])),
        else: query

    paged(query, p, &job_projection/1)
  end

  defp dispatch("task_job_get", p) do
    Repo.one(
      from(j in jobs_query(),
        where: j.id == ^p["job_id"] and fragment("?->>'task_key' = ?", j.args, ^p["key"])
      )
    )
    |> required!()
    |> job_projection()
  end

  defp dispatch("ip_database_catalog", p) do
    result =
      paged(
        from(a in GeoIPArtifact,
          where: a.kind == ^p["kind"],
          order_by: [desc: a.inserted_at, asc: a.digest],
          select: map(a, ~w(digest kind format size inserted_at)a)
        ),
        p,
        &artifact_projection/1
      )

    selected =
      Repo.one(
        from(s in GeoIPSelection,
          join: a in GeoIPArtifact,
          on: a.digest == s.digest,
          where: s.type == ^p["kind"] and a.kind == ^p["kind"],
          select: map(a, ~w(digest kind format size inserted_at)a)
        )
      )

    Map.put(result, "selected", if(selected, do: artifact_projection(selected)))
  end

  defp dispatch("ip_database_artifact", p) do
    Repo.one(
      from(a in GeoIPArtifact,
        where: a.kind == ^p["kind"] and a.digest == ^p["digest"],
        select: map(a, ~w(digest kind format size inserted_at)a)
      )
    )
    |> required!()
    |> artifact_projection()
  end

  defp dispatch("audit_list", p),
    do:
      paged(
        from(a in Audit,
          order_by: [desc: a.inserted_at, desc: a.id],
          select: map(a, ~w(id actor operation inserted_at)a)
        ),
        p
      )

  defp worker!(id),
    do:
      Repo.one(from(w in Worker, where: w.id == ^id, select: map(w, @worker_fields)))
      |> required!()

  defp zone!(id),
    do:
      Repo.one(from(z in Zone, where: z.id == ^id and is_nil(z.deleted_at), select: z.id))
      |> required!()

  defp scoped_service!(p) do
    Repo.one(
      from(s in Service,
        where: s.worker_id == ^p["worker_id"] and s.id == ^p["service_id"] and s.type == "dns",
        select: map(s, @service_fields)
      )
    )
    |> required!()
  end

  defp required!(nil),
    do: throw({:query_error, %{code: "not_found", message: "Management object not found"}})

  defp required!(row), do: row
  defp service_projection(row), do: row |> json() |> Map.put("actual_state", "unknown")

  defp version_projection(row),
    do: row |> json() |> then(&Map.put(Map.delete(&1, "zone_id"), "resource_id", &1["zone_id"]))

  defp artifact_projection(row),
    do: row |> json() |> Map.merge(%{"verification" => "unknown", "available" => nil})

  defp jobs_query do
    from(j in Styx.Job,
      prefix: "management_jobs",
      where:
        j.worker == "YellowDog.Management.SyncGeoIPWorker" and
          fragment("?->>'task_key' IN ('ip_city', 'ip_country')", j.args),
      order_by: [desc: j.id],
      select: %{
        "id" => j.id,
        "task_key" => fragment("?->>'task_key'", j.args),
        "state" => j.state,
        "attempt" => j.attempt,
        "max_attempts" => j.max_attempts,
        "inserted_at" => j.inserted_at,
        "attempted_at" => j.attempted_at,
        "completed_at" => j.completed_at,
        "discarded_at" => j.discarded_at,
        "scheduled_at" => j.scheduled_at
      }
    )
  end

  defp paged(query, p, projection \\ &json/1) do
    page = Map.get(p, "page", 1)
    size = Map.get(p, "page_size", 20)
    rows = Repo.all(from(row in query, limit: ^(size + 1), offset: ^((page - 1) * size)))

    %{
      "items" => rows |> Enum.take(size) |> Enum.map(projection),
      "page" => page,
      "page_size" => size,
      "has_next" => length(rows) > size
    }
  end

  def json(%DateTime{} = value), do: DateTime.to_iso8601(value)
  def json(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)

  def json(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), json(value)} end)

  def json(list) when is_list(list), do: Enum.map(list, &json/1)
  def json(value), do: value
end
