defmodule YellowDog.Management.Operations do
  @moduledoc "Finite shared HTTP/MCP contract. Schemas contain no remote references."
  alias YellowDog.Management.OperationSchemas, as: S

  def all do
    worker = %{"worker_id" => S.identity()}
    zone = %{"zone_id" => S.uuid()}
    selected = Map.put(S.scope(), "id", S.uuid())
    expected_id = Map.merge(%{"id" => S.uuid()}, S.expected())
    target = Map.put(worker, "revision", S.revision())
    task = %{"key" => S.task_key()}
    kind = %{"kind" => S.kind()}

    query = fn id, path, props, output ->
      entry(id, :query, "GET", path, S.object(props), output)
    end

    list = fn id, path, props, output ->
      entry(
        id,
        :query,
        "GET",
        path,
        S.object(Map.merge(props, S.paging()), Map.keys(props)),
        S.page(output)
      )
    end

    command = fn id, domain, method, path, schema, output, scope ->
      entry(id, :command, method, path, schema, output, scope, domain)
    end

    base = [
      list.("worker_list", "/workers", %{}, S.worker()),
      query.("worker_get", "/workers/:worker_id", worker, S.worker()),
      command.(
        "worker_update",
        "update_worker",
        "PATCH",
        "/workers/:worker_id",
        S.object(
          Map.merge(Map.merge(%{"id" => S.identity()}, S.expected()), S.worker_fields()),
          ~w(id expected_revision)
        ),
        S.worker(),
        "nodes:write"
      ),
      list.("service_list", "/workers/:worker_id/services", worker, S.service()),
      query.("service_get", "/workers/:worker_id/services/:service_id", S.scope(), S.service()),
      entry(
        "service_references",
        :query,
        "GET",
        "/workers/:worker_id/services/:service_id/references",
        S.object(Map.merge(S.scope(), S.paging()), ~w(worker_id service_id)),
        reference_schema()
      ),
      command.(
        "service_create",
        "create_service",
        "POST",
        "/workers/:worker_id/services",
        S.object(Map.merge(Map.merge(worker, S.expected()), S.service_fields())),
        S.service(),
        "nodes:write"
      ),
      command.(
        "service_update",
        "update_service",
        "PATCH",
        "/workers/:worker_id/services/:service_id",
        S.object(Map.merge(Map.merge(S.scope(), S.expected()), S.service_fields())),
        S.service(),
        "nodes:write"
      ),
      entry(
        "zone_list",
        :query,
        "GET",
        "/zones",
        S.object(
          Map.merge(S.paging(), %{"search" => S.string(253), "sort" => S.enum(~w(name revision))}),
          []
        ),
        S.page(S.zone_metadata())
      ),
      query.("zone_get", "/zones/:id", %{"id" => S.uuid()}, S.zone()),
      list.("zone_versions", "/zones/:zone_id/versions", zone, S.version()),
      query.(
        "zone_version_get",
        "/zones/:zone_id/versions/:version_id",
        Map.put(zone, "version_id", S.uuid()),
        S.version(true)
      ),
      query.("zone_assignments", "/zones/:zone_id/assignments", zone, S.assignments()),
      command.(
        "zone_create",
        "create_zone",
        "POST",
        "/zones",
        S.zone_input(),
        S.zone(),
        "data:write"
      ),
      command.(
        "zone_update",
        "update_zone",
        "PATCH",
        "/zones/:id",
        S.zone_input(expected_id),
        S.zone(),
        "data:write"
      ),
      command.(
        "zone_delete",
        "delete_zone",
        "DELETE",
        "/zones/:id",
        S.object(expected_id),
        S.object(%{"id" => S.uuid(), "revision" => S.revision(), "deleted" => %{"const" => true}}),
        "data:write"
      ),
      command.(
        "zone_confirm",
        "confirm_zone",
        "POST",
        "/zones/:id/confirm",
        S.object(expected_id),
        S.version(true),
        "data:write"
      ),
      command.(
        "zone_set_assignments",
        "set_zone_assignments",
        "PUT",
        "/zones/:zone_id/assignments",
        S.object(
          Map.merge(zone, %{
            "expected_assignment_token" => S.digest(),
            "expected_worker_revisions" => S.revisions(),
            "assignments" => S.array(S.assignment_input(), 256)
          })
        ),
        S.assignments(),
        "data:write"
      ),
      query.("worker_target_preview", "/workers/:worker_id/target-preview", worker, S.preview()),
      list.("worker_target_history", "/workers/:worker_id/targets", worker, S.target()),
      query.(
        "worker_target_get",
        "/workers/:worker_id/targets/:revision",
        target,
        target_with_scope()
      ),
      query.(
        "worker_target_export",
        "/workers/:worker_id/targets/:revision/export",
        target,
        S.object(%{
          "target" => S.target(true),
          "plan" => S.plan(),
          "digest" => S.digest(),
          "toml" => S.text(1_048_576),
          "export_scope" => S.export_scope()
        })
      ),
      command.(
        "worker_target_publish",
        "confirm_target",
        "POST",
        "/workers/:worker_id/targets",
        S.object(Map.merge(worker, S.expected())),
        S.published_target(),
        "targets:publish"
      ),
      list.("task_list", "/tasks", %{}, S.task()),
      query.("task_get", "/tasks/:key", task, S.task()),
      command.(
        "task_update",
        "update_task",
        "PATCH",
        "/tasks/:key",
        S.object(
          Map.merge(Map.merge(task, S.expected()), %{
            "enabled" => S.boolean(),
            "cron" => S.text(128)
          })
        ),
        S.task(),
        "sync:settings"
      ),
      entry(
        "task_jobs",
        :query,
        "GET",
        "/task-jobs",
        S.object(Map.merge(task, S.paging()), []),
        S.page(S.job())
      ),
      query.(
        "task_job_get",
        "/tasks/:key/jobs/:job_id",
        Map.put(task, "job_id", S.integer(1, 9_223_372_036_854_775_807)),
        S.job()
      ),
      entry(
        "ip_database_catalog",
        :query,
        "GET",
        "/ip-databases/:kind/artifacts",
        S.object(Map.merge(kind, S.paging()), ["kind"]),
        Map.update!(
          S.page(S.artifact()),
          "properties",
          &Map.put(&1, "selected", S.nullable(S.artifact()))
        )
        |> Map.update!("required", &["selected" | &1])
      ),
      query.(
        "ip_database_artifact",
        "/ip-databases/:kind/artifacts/:digest",
        Map.put(kind, "digest", S.digest()),
        S.artifact()
      ),
      command.(
        "ip_database_sync",
        "run_task",
        "POST",
        "/ip-databases/:key/sync",
        S.object(task),
        S.job(),
        "sync:run"
      ),
      entry(
        "audit_list",
        :query,
        "GET",
        "/audit",
        S.object(S.paging(), []),
        S.page(S.audit()),
        "audit:read"
      )
    ]

    scoped =
      Enum.flat_map([{"dns_view", "views", S.view()}, {"dns_acl", "acls", S.acl()}], fn {id,
                                                                                         plural,
                                                                                         output} ->
        path = "/workers/:worker_id/dns-services/:service_id/" <> plural
        fields = if id == "dns_view", do: S.view_fields(), else: S.acl_fields()

        create =
          Map.merge(
            S.scope(),
            Map.put(
              fields,
              "name",
              if(id == "dns_view",
                do: Map.put(S.text(63), "pattern", "^[A-Za-z0-9_-]+$"),
                else: fields["name"]
              )
            )
          )

        create_required =
          if id == "dns_view",
            do: ~w(worker_id service_id name),
            else: ~w(worker_id service_id name description rules)

        update = Map.merge(Map.merge(selected, S.expected()), fields)

        update_required =
          if id == "dns_view",
            do: ~w(worker_id service_id id expected_revision),
            else: Map.keys(update)

        [
          list.(id <> "_list", path, S.scope(), scoped_metadata(id)),
          query.(id <> "_get", path <> "/:id", selected, output),
          command.(
            id <> "_create",
            "create_" <> id,
            "POST",
            path,
            S.object(create, create_required),
            output,
            "data:write"
          ),
          command.(
            id <> "_update",
            "update_" <> id,
            "PATCH",
            path <> "/:id",
            S.object(update, update_required),
            output,
            "data:write"
          ),
          command.(
            id <> "_delete",
            "delete_" <> id,
            "DELETE",
            path <> "/:id",
            S.object(Map.merge(selected, S.expected())),
            output,
            "data:write"
          )
        ]
      end)

    base ++ scoped
  end

  def get(id) do
    case Enum.find(all(), &(&1.id == id)) do
      nil -> {:error, %{code: "not_found", message: "Unknown Management operation"}}
      operation -> {:ok, operation}
    end
  end

  defp entry(id, kind, method, path, input, output, scope \\ "config:read", domain \\ nil) do
    %{
      id: id,
      kind: kind,
      method: method,
      path: "/api/v1" <> path,
      input_schema: input,
      output_schema: output,
      scope: scope,
      domain_operation: domain,
      description: String.replace(id, "_", " "),
      annotations: %{
        "readOnlyHint" => kind == :query,
        "destructiveHint" => kind == :command,
        "idempotentHint" => true,
        "openWorldHint" => false
      }
    }
  end

  defp scoped_metadata("dns_view"),
    do:
      S.object(%{
        "id" => S.uuid(),
        "name" => S.text(63),
        "revision" => S.revision(),
        "is_default" => S.boolean(),
        "enabled" => S.boolean(),
        "priority" => S.nullable(S.integer(0, 9_223_372_036_854_775_807))
      })

  defp scoped_metadata("dns_acl"),
    do:
      S.object(%{
        "id" => S.uuid(),
        "name" => S.text(128),
        "revision" => S.revision(),
        "description" => S.string(255)
      })

  defp target_with_scope,
    do:
      S.target(true)
      |> Map.update!("properties", &Map.put(&1, "export_scope", S.export_scope()))
      |> Map.update!("required", &["export_scope" | &1])

  defp reference_schema do
    zone =
      S.object(%{
        "id" => S.uuid(),
        "zone_id" => S.uuid(),
        "name" => S.text(253),
        "resource_version_id" => S.uuid(),
        "version" => S.revision(),
        "digest" => S.digest()
      })

    view =
      S.object(%{
        "id" => S.uuid(),
        "name" => S.text(63),
        "revision" => S.revision(),
        "is_default" => S.boolean()
      })

    acl = S.object(%{"id" => S.uuid(), "name" => S.text(128), "revision" => S.revision()})
    S.object(%{"zones" => S.page(zone), "views" => S.page(view), "acls" => S.page(acl)})
  end
end
