defmodule YellowDog.Console.DnsZoneController do
  @moduledoc "Authenticated HTTP presentation for management-owned DNS zones."
  use YellowDog.Console, :controller

  alias YellowDog.Management.DnsZones
  alias YellowDog.Management.Servers
  alias YellowDog.Console.ServerConnections

  @max_body_bytes 65_536

  def index(conn, _params), do: json(conn, %{"zones" => DnsZones.list()})

  def servers(conn, _params),
    do: json(conn, %{"servers" => Enum.map(Servers.list(), &server_json/1)})

  def show(conn, %{"id" => id}) do
    respond(conn, DnsZones.get(id), 200)
  end

  def rrsets(conn, %{"id" => id}) do
    case DnsZones.get(id) do
      {:ok, zone} -> json(conn, %{"rrsets" => zone["rrsets"], "revision" => zone["revision"]})
      error -> respond(conn, error, 200)
    end
  end

  def create(conn, params) do
    with :ok <- bounded(params),
         :ok <- allowed_keys(params, ~w(apex targets rrsets)),
         {:ok, key} <- idempotency_key(conn),
         result <-
           DnsZones.create(params, conn.assigns.api_actor, key) do
      respond(conn, result, 201)
    else
      error -> respond(conn, error, 201)
    end
  end

  def edit(conn, %{"id" => id} = params) do
    with :ok <- bounded(params),
         :ok <- allowed_keys(params, ~w(id expected_revision edits)),
         {:ok, key} <- idempotency_key(conn),
         result <-
           DnsZones.edit(
             id,
             params["expected_revision"],
             params["edits"],
             conn.assigns.api_actor,
             key
           ) do
      respond(conn, result, 200)
    else
      error -> respond(conn, error, 200)
    end
  end

  def publish(conn, %{"id" => id} = params) do
    with :ok <- bounded(params),
         :ok <- allowed_keys(params, ~w(id expected_revision)),
         {:ok, key} <- idempotency_key(conn),
         result <- DnsZones.publish(id, params["expected_revision"], conn.assigns.api_actor, key) do
      respond(conn, result, 202)
    else
      error -> respond(conn, error, 202)
    end
  end

  def deployment(conn, %{"id" => id}) do
    respond(conn, DnsZones.deployment(id), 200)
  end

  defp respond(conn, {:ok, value}, status), do: conn |> put_status(status) |> json(value)

  defp respond(conn, {:error, %YellowDog.Sync.Error{code: code}}, status),
    do: respond(conn, {:error, code}, status)

  defp respond(conn, {:error, code}, _status) do
    status =
      case code do
        :not_found -> 404
        :conflict -> 409
        :invalid_idempotency_key -> 400
        :too_large -> 413
        :internal -> 500
        _ -> 422
      end

    conn
    |> put_status(status)
    |> json(%{"error" => %{"code" => to_string(code), "message" => error_message(code)}})
  end

  defp bounded(params) do
    if byte_size(Jason.encode!(params)) <= @max_body_bytes, do: :ok, else: {:error, :too_large}
  end

  defp allowed_keys(params, keys) do
    if Enum.all?(Map.keys(params), &(&1 in keys)), do: :ok, else: {:error, :invalid_fields}
  end

  defp idempotency_key(conn) do
    case get_req_header(conn, "idempotency-key") do
      [key] when byte_size(key) in 1..128 -> {:ok, key}
      _ -> {:error, :invalid_idempotency_key}
    end
  end

  defp error_message(:conflict), do: "revision or idempotency conflict"
  defp error_message(:not_found), do: "resource not found"
  defp error_message(:too_large), do: "request exceeds 65536 bytes"
  defp error_message(_), do: "invalid request"

  defp server_json(server) do
    %{
      "id" => server.id,
      "name" => server.name,
      "status" => to_string(server.status),
      "profile" => to_string(server.profile),
      "dns_capable" => Map.get(server.services, :dns, false),
      "connected" => ServerConnections.connected?(server.id)
    }
  end
end
