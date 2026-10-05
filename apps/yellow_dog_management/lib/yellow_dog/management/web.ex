defmodule YellowDog.Management.Web do
  @moduledoc "Management API without built-in authentication."
  use Plug.Router
  alias YellowDog.Management.{Backups, ConfigCompiler, Domain}

  plug(:headers)

  plug(:match)
  plug(:parse_body)
  plug(:dispatch)

  get "/api/workers" do
    json(conn, 200, %{"data" => Domain.list_workers()})
  end

  get "/api/workers/:id" do
    respond(conn, Domain.get_worker(id))
  end

  get "/api/workers/:worker_id/dns-services/:service_id/acls" do
    respond(conn, Domain.list_dns_acls(worker_id, service_id))
  end

  get "/api/workers/:worker_id/dns-services/:service_id/acls/:id" do
    respond(conn, Domain.get_dns_acl(worker_id, service_id, id))
  end

  get "/api/workers/:worker_id/dns-services/:service_id/views" do
    respond(conn, Domain.list_dns_views(worker_id, service_id))
  end

  get "/api/workers/:worker_id/dns-services/:service_id/views/:id" do
    respond(conn, Domain.get_dns_view(worker_id, service_id, id))
  end

  get "/api/netmans" do
    json(conn, 200, %{"data" => Domain.list_netmans()})
  end

  get "/api/netmans/:id" do
    respond(conn, Domain.get_netman(id))
  end

  get "/api/netmans/:id/config" do
    respond(conn, Domain.get_netman_config(id))
  end

  get "/api/netmans/:id/versions" do
    case Domain.get_netman(id) do
      {:ok, _node} -> json(conn, 200, %{"data" => Domain.list_netman_versions(id)})
      error -> respond(conn, error)
    end
  end

  get "/api/zones" do
    json(conn, 200, %{"data" => Domain.list_zones()})
  end

  get "/api/tasks" do
    json(conn, 200, %{"data" => Domain.list_tasks()})
  end

  get "/api/tasks/:key" do
    respond(conn, Domain.get_task(key))
  end

  get "/api/tasks/:key/jobs" do
    case Domain.get_task(key) do
      {:ok, _task} -> json(conn, 200, %{"data" => Domain.list_task_jobs(key)})
      error -> respond(conn, error)
    end
  end

  get "/api/task-history" do
    json(conn, 200, %{"data" => Domain.list_task_history()})
  end

  get "/api/backups" do
    json(conn, 200, %{"data" => Backups.list()})
  end

  get "/api/backups/:id" do
    respond(conn, Backups.get(id))
  end

  get "/api/backups/:id/download" do
    case Backups.download(id, fn path ->
           {:ok,
            conn
            |> put_resp_content_type("application/x-tar")
            |> put_resp_header(
              "content-disposition",
              "attachment; filename=management-backup-#{id}.tar"
            )
            |> send_file(200, path)}
         end) do
      {:ok, sent} -> sent
      error -> respond(conn, error)
    end
  end

  get "/api/backups/:id/verify" do
    respond(conn, Backups.verify(id))
  end

  get "/api/zones/:id" do
    respond(conn, Domain.get_zone(id))
  end

  get "/api/zones/:id/versions" do
    json(conn, 200, %{"data" => Domain.list_versions(id)})
  end

  get "/api/workers/:id/preview" do
    respond(conn, Domain.preview_target(id))
  end

  get "/api/workers/:id/targets/:revision" do
    with {:ok, revision} <- revision(revision) do
      respond(conn, Domain.get_target(id, revision))
    else
      error -> respond(conn, error)
    end
  end

  get "/api/workers/:id/targets/:revision/export" do
    with {:ok, revision} <- revision(revision),
         {:ok, %{"toml" => toml, "target" => target}} <-
           ConfigCompiler.export_target(id, revision) do
      conn
      |> put_resp_content_type("application/toml")
      |> put_resp_header(
        "content-disposition",
        "attachment; filename=target-#{target["revision"]}.toml"
      )
      |> send_resp(200, toml)
    else
      error -> respond(conn, error)
    end
  end

  post "/api/commands/:operation" do
    case get_req_header(conn, "idempotency-key") do
      [key] when byte_size(key) in 1..128 ->
        respond(conn, Domain.mutate(operation, conn.body_params, "operator", key))

      _ ->
        respond(
          conn,
          {:error,
           %{code: "invalid_request", message: "Idempotency-Key is required (1..128 bytes)"}}
        )
    end
  end

  match _ do
    json(conn, 404, %{error: %{code: "not_found", message: "Route not found"}})
  end

  defp headers(conn, _) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header(
      "content-security-policy",
      "default-src 'none'; script-src 'self'; connect-src 'self'; style-src 'self'; img-src 'self' data:; base-uri 'none'; frame-ancestors 'none'; form-action 'self'"
    )
  end

  defp parse_body(conn, _) do
    Plug.Parsers.call(
      conn,
      Plug.Parsers.init(parsers: [:json], json_decoder: Jason, length: 1_048_576)
    )
  rescue
    Plug.Parsers.RequestTooLargeError ->
      conn
      |> json(413, %{error: %{code: "input_limit", message: "Request exceeds 1 MiB"}})
      |> halt()

    Plug.Parsers.ParseError ->
      conn |> json(400, %{error: %{code: "invalid_json", message: "Invalid JSON body"}}) |> halt()

    Plug.Parsers.UnsupportedMediaTypeError ->
      conn
      |> json(415, %{error: %{code: "unsupported_media_type", message: "Use application/json"}})
      |> halt()
  end

  defp revision("latest"), do: {:ok, :latest}

  defp revision(value) do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> {:error, %{code: "invalid_request", message: "Revision must be a positive integer"}}
    end
  end

  defp respond(conn, {:ok, result}), do: json(conn, 200, %{data: result})

  defp respond(conn, {:error, error}) do
    code = Map.get(error, :code) || Map.get(error, "code")

    status =
      case code do
        "not_found" -> 404
        "conflict" -> 409
        "revision_conflict" -> 409
        "idempotency_conflict" -> 409
        "assigned" -> 409
        _ -> 422
      end

    json(conn, status, %{error: error})
  end

  defp json(conn, status, data) do
    conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(data))
  end
end
