defmodule YellowDog.Management.HTTPAPI do
  @moduledoc "Finite versioned HTTP adapter over the shared authorized Management facade."
  @behaviour Plug
  import Plug.Conn
  alias YellowDog.Management.{Access, ApplicationAPI, Auth, OpenAPI, Operations}
  @max_body 1_048_576
  def init(opts), do: opts

  def call(conn, _opts) do
    case Auth.authenticate(conn, :http) do
      {:ok, caller} -> dispatch(conn, caller)
      {:error, error} -> respond_error(conn, error, Ecto.UUID.generate())
    end
  rescue
    error in [Plug.Conn.InvalidQueryError] ->
      _ = error

      respond_error(
        conn,
        %{code: "invalid_request", message: "Malformed query parameters"},
        Ecto.UUID.generate()
      )
  end

  defp dispatch(%{method: "GET", request_path: "/api/v1/openapi.json"} = conn, caller) do
    case Access.authorize(caller, "config:read") do
      :ok -> json(conn, 200, OpenAPI.document())
      {:error, error} -> respond_error(conn, error, caller.correlation_id)
    end
  end

  defp dispatch(conn, caller) do
    case route(conn.method, conn.request_path) do
      nil ->
        respond_error(
          conn,
          %{code: "not_found", message: "Unknown Management endpoint"},
          caller.correlation_id
        )

      {operation, path_params} ->
        with {:ok, params, conn} <- parameters(conn, operation, path_params) do
          result =
            case operation.kind do
              :query -> ApplicationAPI.query(caller, operation.id, params)
              :command -> ApplicationAPI.command(caller, operation.id, params, logical_key(conn))
            end

          case result do
            {:ok, data} ->
              json(conn, 200, %{"data" => data, "correlation_id" => caller.correlation_id})

            {:error, error} ->
              respond_error(conn, error, caller.correlation_id)
          end
        else
          {:error, error} -> respond_error(conn, error, caller.correlation_id)
        end
    end
  end

  defp route(method, path) do
    actual = String.split(path, "/", trim: true)

    Enum.find_value(Operations.all(), fn operation ->
      expected = String.split(operation.path, "/", trim: true)

      if operation.method == method and length(expected) == length(actual) do
        bindings = Enum.zip(expected, actual)

        if Enum.all?(bindings, fn {a, b} -> String.starts_with?(a, ":") or a == b end) do
          params = for {":" <> key, value} <- bindings, into: %{}, do: {key, URI.decode(value)}

          params =
            if operation.id == "worker_update",
              do: Map.put(Map.delete(params, "worker_id"), "id", params["worker_id"]),
              else: params

          {operation, params}
        end
      end
    end)
  end

  defp parameters(conn, operation, path) do
    conn = fetch_query_params(conn)

    with {:ok, body, conn} <- body(conn, operation.kind),
         :ok <- matching_identities(path, body),
         :ok <- matching_identities(path, conn.query_params),
         :ok <- no_overlap(body, conn.query_params) do
      params = conn.query_params |> Map.merge(body) |> Map.merge(path)
      # URL values have textual encodings; JSON body values retain their JSON types.
      textual = Map.merge(conn.query_params, path) |> Map.keys()

      params =
        Map.new(params, fn {key, value} ->
          schema = operation.input_schema["properties"][key]

          {key,
           if((key in textual and schema) && schema["type"] == "integer",
             do: parse_integer(value),
             else: value
           )}
        end)

      {:ok, params, conn}
    end
  end

  defp body(conn, :query), do: {:ok, %{}, conn}

  defp body(%{body_params: %Plug.Conn.Unfetched{}} = conn, :command) do
    case read_body(conn, length: @max_body, read_length: @max_body, read_timeout: 5_000) do
      {:ok, "", conn} ->
        {:ok, %{}, conn}

      {:ok, bytes, conn} ->
        if json_content_type?(conn) do
          case Jason.decode(bytes) do
            {:ok, map} when is_map(map) -> {:ok, map, conn}
            _ -> invalid("Request body must be a JSON object")
          end
        else
          invalid("Content-Type must be application/json")
        end

      {:more, _, _} ->
        {:error, %{code: "payload_too_large", message: "Request body exceeds 1048576 bytes"}}

      {:error, _} ->
        invalid("Request body could not be read")
    end
  end

  defp body(%{body_params: params} = conn, :command) when is_map(params), do: {:ok, params, conn}

  defp json_content_type?(conn) do
    case get_req_header(conn, "content-type") do
      [value] ->
        case Plug.Conn.Utils.media_type(value) do
          {:ok, "application", "json", parameters} ->
            String.downcase(Map.get(parameters, "charset", "utf-8")) == "utf-8"

          _ ->
            false
        end

      _ ->
        false
    end
  end

  defp matching_identities(path, values) do
    if Enum.any?(path, fn {key, value} -> Map.has_key?(values, key) and values[key] != value end),
      do: invalid("Path and payload identities disagree"),
      else: :ok
  end

  defp no_overlap(body, query) do
    if Enum.any?(Map.keys(body), &Map.has_key?(query, &1)),
      do: invalid("A parameter must occur in one request location"),
      else: :ok
  end

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> value
    end
  end

  defp parse_integer(value), do: value

  defp logical_key(conn) do
    case get_req_header(conn, "idempotency-key") do
      [value] -> value
      _ -> nil
    end
  end

  defp invalid(message), do: {:error, %{code: "invalid_request", message: message}}

  def status(%{code: code}) when code in ~w(authentication_required invalid_token missing),
    do: 401

  def status(%{code: "forbidden"}), do: 403
  def status(%{code: "not_found"}), do: 404

  def status(%{code: code})
      when code in ~w(conflict revision_conflict assignment_conflict idempotency_conflict assigned),
      do: 409

  def status(%{code: "payload_too_large"}), do: 413
  def status(%{code: "rate_limited"}), do: 429

  def status(%{code: code}) when code in ~w(database_unavailable adapters_disabled unavailable),
    do: 503

  def status(%{code: "invalid_request"}), do: 400
  def status(_), do: 422

  def respond_error(conn, error, correlation) do
    conn
    |> Auth.challenge(error)
    |> json(status(error), %{"error" => error, "correlation_id" => correlation})
  end

  defp json(conn, status, body),
    do:
      conn
      |> put_resp_content_type("application/json")
      |> put_resp_header("cache-control", "no-store")
      |> send_resp(status, Jason.encode!(body))
end
