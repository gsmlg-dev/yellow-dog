defmodule YellowDog.Management.MCP do
  @moduledoc "Stateless JSON Streamable HTTP adapter for MCP 2025-11-25."
  @behaviour Plug
  import Plug.Conn
  alias YellowDog.Management.{Access, ApplicationAPI, Auth, Operations}

  @protocol "2025-11-25"
  @body_limit 1_048_576
  @logical_key "logical_request_key"

  def protocol_version, do: @protocol
  def body_limit, do: @body_limit
  def init(options), do: options

  def call(conn, _options) do
    conn =
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("x-content-type-options", "nosniff")

    case Auth.authenticate(conn, :mcp) do
      {:ok, caller} -> dispatch(conn, caller)
      {:error, error} -> conn |> Auth.challenge(error) |> transport_error(status(error), error)
    end
  end

  defp dispatch(%{path_info: path} = conn, _caller) when path not in [[], [""]],
    do: transport_error(conn, 404, %{code: "not_found", message: "MCP endpoint not found"})

  defp dispatch(%{method: method} = conn, _caller) when method != "POST" do
    conn
    |> put_resp_header("allow", "POST")
    |> transport_error(405, %{
      code: "method_not_allowed",
      message: "Use POST; this stateless endpoint provides no GET stream or sessions"
    })
  end

  defp dispatch(conn, caller) do
    with :ok <- content_type(conn),
         :ok <- accepted_types(conn),
         {:ok, body, conn} <- read_message(conn),
         {:ok, message} <- decode_message(body),
         :ok <- protocol_header(conn, message) do
      handle_message(conn, caller, message)
    else
      {:error, status, error} -> transport_error(conn, status, error)
      {:rpc_error, code, message} -> rpc_error(conn, 400, nil, code, message)
    end
  end

  defp content_type(conn) do
    case get_req_header(conn, "content-type") do
      [value] ->
        case Plug.Conn.Utils.media_type(value) do
          {:ok, "application", "json", params} ->
            if String.downcase(Map.get(params, "charset", "utf-8")) == "utf-8",
              do: :ok,
              else: unsupported_media()

          _ ->
            unsupported_media()
        end

      _ ->
        unsupported_media()
    end
  end

  defp unsupported_media,
    do:
      {:error, 415,
       %{
         code: "unsupported_media_type",
         message: "Content-Type must be application/json with UTF-8 encoding"
       }}

  defp accepted_types(conn) do
    types =
      conn
      |> get_req_header("accept")
      |> Enum.flat_map(&String.split(&1, ","))
      |> Enum.flat_map(fn value ->
        case Plug.Conn.Utils.media_type(String.trim(value)) do
          {:ok, type, subtype, parameters} ->
            if Map.get(parameters, "q", "1") in ["0", "0.0", "0.00", "0.000"],
              do: [],
              else: [type <> "/" <> subtype]

          _ ->
            []
        end
      end)

    if "application/json" in types and "text/event-stream" in types,
      do: :ok,
      else:
        {:error, 406,
         %{
           code: "not_acceptable",
           message: "Accept must include application/json and text/event-stream"
         }}
  end

  defp read_message(conn) do
    case read_body(conn, length: @body_limit, read_length: @body_limit, read_timeout: 5_000) do
      {:ok, body, conn} ->
        {:ok, body, conn}

      {:more, _body, _conn} ->
        {:error, 413, %{code: "request_too_large", message: "MCP body exceeds 1048576 bytes"}}

      {:error, _reason} ->
        {:error, 400, %{code: "invalid_request", message: "MCP body could not be read"}}
    end
  end

  defp decode_message(body) do
    case Jason.decode(body) do
      {:ok, %{"jsonrpc" => "2.0", "method" => method} = message} when is_binary(method) ->
        if valid_id?(message) and is_map(Map.get(message, "params", %{})) and
             only_keys?(message, ~w(jsonrpc method params id)) and
             (method != "initialize" or Map.has_key?(message, "id")),
           do: {:ok, message},
           else: {:rpc_error, -32600, "Invalid JSON-RPC request"}

      {:ok, %{"jsonrpc" => "2.0", "id" => _id} = message} ->
        if valid_id?(message) and valid_response?(message),
          do: {:ok, message},
          else: {:rpc_error, -32600, "Invalid JSON-RPC response"}

      {:ok, _} ->
        {:rpc_error, -32600, "Expected one JSON-RPC 2.0 request or notification"}

      {:error, _} ->
        {:rpc_error, -32700, "Invalid JSON"}
    end
  end

  defp valid_id?(%{"id" => id}), do: is_integer(id) or (is_binary(id) and byte_size(id) <= 256)
  defp valid_id?(_message), do: true

  defp valid_response?(%{"result" => result} = message),
    do: is_map(result) and only_keys?(message, ~w(jsonrpc id result))

  defp valid_response?(%{"error" => %{"code" => code, "message" => text} = error} = message),
    do:
      is_integer(code) and is_binary(text) and only_keys?(error, ~w(code message data)) and
        only_keys?(message, ~w(jsonrpc id error))

  defp valid_response?(_message), do: false

  defp protocol_header(conn, message) do
    method = Map.get(message, "method")

    case get_req_header(conn, "mcp-protocol-version") do
      [@protocol] ->
        :ok

      [] when method == "initialize" ->
        :ok

      _ ->
        {:error, 400,
         %{
           code: "unsupported_protocol_version",
           message: "MCP-Protocol-Version must be #{@protocol}"
         }}
    end
  end

  defp handle_message(conn, caller, message) do
    params = Map.get(message, "params", %{})

    cond do
      not is_map(Map.get(params, "_meta", %{})) ->
        rpc_error(
          conn,
          if(Map.has_key?(message, "id"), do: 200, else: 400),
          message["id"],
          -32602,
          "_meta must be an object"
        )

      not Map.has_key?(message, "id") or not Map.has_key?(message, "method") ->
        send_resp(conn, 202, "")

      true ->
        handle_request(conn, caller, message["id"], message["method"], params)
    end
  end

  defp handle_request(conn, _caller, id, "initialize", params) do
    if valid_initialize?(params) do
      result(conn, id, %{
        "protocolVersion" => @protocol,
        "capabilities" => %{"tools" => %{"listChanged" => false}},
        "serverInfo" => %{
          "name" => "yellow-dog-management",
          "version" => Application.spec(:yellow_dog_management, :vsn) |> to_string()
        },
        "instructions" =>
          "Management configuration only. Writes require a stable logical_request_key. Save, confirm, assign and publish are separate actions. Worker execution is not implied."
      })
    else
      rpc_error(
        conn,
        200,
        id,
        -32602,
        "initialize requires protocolVersion, capabilities and clientInfo name/version"
      )
    end
  end

  defp handle_request(conn, _caller, id, "ping", params) do
    if only_keys?(params, ~w(_meta)), do: result(conn, id, %{}), else: invalid_params(conn, id)
  end

  defp handle_request(conn, caller, id, "tools/list", params) do
    if only_keys?(params, ~w(_meta)) do
      tools = Operations.all() |> Enum.filter(&authorized?(caller, &1.scope)) |> Enum.map(&tool/1)
      result(conn, id, %{"tools" => tools})
    else
      rpc_error(
        conn,
        200,
        id,
        -32602,
        "This finite tool catalog has no cursor; omit cursor and unknown fields"
      )
    end
  end

  defp handle_request(conn, caller, id, "tools/call", %{"name" => name} = params)
       when is_binary(name) do
    arguments = Map.get(params, "arguments", %{})

    if only_keys?(params, ~w(name arguments _meta)) and is_map(arguments) do
      case Operations.get(name) do
        {:ok, operation} ->
          outcome =
            case operation.kind do
              :query ->
                ApplicationAPI.query(caller, name, arguments)

              :command ->
                {key, arguments} = Map.pop(arguments, @logical_key)
                ApplicationAPI.command(caller, name, arguments, key)
            end

          tool_result(conn, caller, id, outcome)

        {:error, _} ->
          rpc_error(conn, 200, id, -32602, "Unknown tool")
      end
    else
      invalid_params(conn, id)
    end
  end

  defp handle_request(conn, _caller, id, "tools/call", _params), do: invalid_params(conn, id)

  defp handle_request(conn, _caller, id, _method, _params),
    do: rpc_error(conn, 200, id, -32601, "Method not found")

  defp valid_initialize?(%{
         "protocolVersion" => version,
         "capabilities" => capabilities,
         "clientInfo" => %{"name" => name, "version" => client_version}
       }) do
    is_binary(version) and byte_size(version) in 1..64 and is_map(capabilities) and
      is_binary(name) and byte_size(name) in 1..128 and is_binary(client_version) and
      byte_size(client_version) in 1..128
  end

  defp valid_initialize?(_params), do: false
  defp only_keys?(params, keys), do: Enum.all?(Map.keys(params), &(&1 in keys))
  defp authorized?(caller, scope), do: Access.authorize(caller, scope) == :ok
  defp invalid_params(conn, id), do: rpc_error(conn, 200, id, -32602, "Invalid method parameters")

  defp tool(operation) do
    schema = operation.input_schema

    schema =
      if operation.kind == :command do
        schema
        |> Map.update!(
          "properties",
          &Map.put(&1, @logical_key, %{
            "type" => "string",
            "minLength" => 1,
            "maxLength" => 128,
            "description" =>
              "Stable caller/client request identity; reuse unchanged after a lost response. Use a new key for a new intent."
          })
        )
        |> Map.update("required", [@logical_key], &(&1 ++ [@logical_key]))
      else
        schema
      end

    %{
      "name" => operation.id,
      "description" => operation.description,
      "inputSchema" => schema,
      "outputSchema" => output_schema(operation.output_schema),
      "annotations" => operation.annotations
    }
  end

  defp output_schema(data_schema) do
    %{
      "type" => "object",
      "oneOf" => [
        %{
          "type" => "object",
          "required" => ["data", "correlation_id"],
          "additionalProperties" => false,
          "properties" => %{"data" => data_schema, "correlation_id" => %{"type" => "string"}}
        },
        %{
          "type" => "object",
          "required" => ["error", "correlation_id"],
          "additionalProperties" => false,
          "properties" => %{
            "error" => %{
              "type" => "object",
              "required" => ["code", "message"],
              "properties" => %{
                "code" => %{"type" => "string"},
                "message" => %{"type" => "string"},
                "details" => %{"type" => "object"}
              }
            },
            "correlation_id" => %{"type" => "string"}
          }
        }
      ]
    }
  end

  defp tool_result(conn, caller, id, {:ok, data}) do
    structured = %{"data" => data, "correlation_id" => caller.correlation_id}

    result(conn, id, %{
      "content" => [%{"type" => "text", "text" => Jason.encode!(structured)}],
      "structuredContent" => structured,
      "isError" => false
    })
  end

  defp tool_result(conn, caller, id, {:error, error}) do
    structured = %{"error" => error, "correlation_id" => caller.correlation_id}

    result(conn, id, %{
      "content" => [%{"type" => "text", "text" => Jason.encode!(structured)}],
      "structuredContent" => structured,
      "isError" => true
    })
  end

  defp result(conn, id, value),
    do: json(conn, 200, %{"jsonrpc" => "2.0", "id" => id, "result" => value})

  defp rpc_error(conn, status, id, code, message),
    do:
      json(conn, status, %{
        "jsonrpc" => "2.0",
        "id" => id,
        "error" => %{"code" => code, "message" => message}
      })

  defp transport_error(conn, status, error), do: json(conn, status, %{"error" => error})

  defp json(conn, status, body),
    do:
      conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(body))

  defp status(%{code: code}) when code in ["authentication_required", "invalid_token"], do: 401
  defp status(%{code: code}) when code in ["forbidden", "invalid_origin", "invalid_host"], do: 403
  defp status(%{code: "adapters_disabled"}), do: 503
  defp status(_error), do: 403
end
