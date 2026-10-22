defmodule YellowDog.Management.OpenAPI do
  @moduledoc "OpenAPI 3.1.2 generated directly from the finite shared operation schemas."
  alias YellowDog.Management.{Operations, OperationSchemas}

  def document do
    paths =
      Enum.reduce(Operations.all(), %{}, fn operation, paths ->
        path = Regex.replace(~r/:([a-z_]+)/, operation.path, "{\\1}")

        Map.update(
          paths,
          path,
          %{String.downcase(operation.method) => operation_document(operation)},
          &Map.put(&1, String.downcase(operation.method), operation_document(operation))
        )
      end)

    %{
      "openapi" => "3.1.2",
      "jsonSchemaDialect" => "https://json-schema.org/draft/2020-12/schema",
      "info" => %{
        "title" => "Yellow Dog Management API",
        "version" => "1.0.0",
        "description" =>
          "Management configuration only. DNS Views, ACLs and IP artifacts are excluded from Worker targets. Remote adapters require explicit enablement and verified authorization.",
        "license" => %{"name" => "Private deployment"}
      },
      "servers" => [%{"url" => "/"}],
      "paths" => paths,
      "components" => %{
        "securitySchemes" => %{
          "bearerAuth" => %{
            "type" => "http",
            "scheme" => "bearer",
            "bearerFormat" => "JWT",
            "description" =>
              "Externally issued OAuth access token. See protected-resource metadata for issuer and scopes; no local token endpoint."
          }
        }
      },
      "security" => [%{"bearerAuth" => []}]
    }
  end

  def write!(path), do: File.write!(path, Jason.encode!(document(), pretty: true) <> "\n")

  def success_schema(operation),
    do:
      OperationSchemas.object(%{
        "data" => operation.output_schema,
        "correlation_id" => OperationSchemas.text(128)
      })

  def error_schema,
    do:
      OperationSchemas.object(%{
        "error" => OperationSchemas.error(),
        "correlation_id" => OperationSchemas.text(128)
      })

  defp operation_document(operation) do
    path_names =
      Regex.scan(~r/:([a-z_]+)/, operation.path, capture: :all_but_first) |> List.flatten()

    properties = operation.input_schema["properties"]
    required = operation.input_schema["required"]

    bindings =
      Map.new(path_names, fn name ->
        {name, if(operation.id == "worker_update" and name == "worker_id", do: "id", else: name)}
      end)

    path_keys = Map.values(bindings)

    parameters =
      Enum.map(bindings, fn {name, key} ->
        %{"name" => name, "in" => "path", "required" => true, "schema" => properties[key]}
      end)

    parameters =
      if operation.kind == :query do
        parameters ++
          Enum.map(Map.drop(properties, path_keys), fn {name, schema} ->
            %{"name" => name, "in" => "query", "required" => name in required, "schema" => schema}
          end)
      else
        parameters ++
          [
            %{
              "name" => "Idempotency-Key",
              "in" => "header",
              "required" => true,
              "description" =>
                "Stable logical intent, 1..128 bytes, namespaced by verified principal/client. Replays across HTTP and MCP.",
              "schema" => OperationSchemas.text(128)
            }
          ]
      end

    errors =
      for code <- [400, 401, 403, 404, 409, 413, 422, 429, 503],
          into: %{},
          do:
            {to_string(code),
             %{
               "description" => error_description(code),
               "content" => %{"application/json" => %{"schema" => error_schema()}}
             }}

    doc = %{
      "operationId" => operation.id,
      "summary" => operation.description,
      "description" =>
        "Required scope: #{operation.scope}. " <>
          if(operation.kind == :command,
            do:
              "Requires a stable logical request key and all declared concurrency preconditions.",
            else: "Side-effect-free bounded read."
          ),
      "tags" => ["Management"],
      "parameters" => parameters,
      "responses" =>
        Map.put(errors, "200", %{
          "description" => "Canonical Management result",
          "content" => %{"application/json" => %{"schema" => success_schema(operation)}}
        }),
      "x-required-scope" => operation.scope
    }

    if operation.kind == :command do
      schema =
        operation.input_schema
        |> Map.put("properties", Map.drop(properties, path_keys))
        |> Map.put("required", required -- path_keys)

      Map.put(doc, "requestBody", %{
        "required" => true,
        "description" =>
          "Closed JSON object; maximum 1048576 bytes. Path identities cannot be overridden.",
        "content" => %{"application/json" => %{"schema" => schema}}
      })
    else
      doc
    end
  end

  defp error_description(400), do: "Malformed request or schema violation"
  defp error_description(401), do: "Valid authentication required"
  defp error_description(403), do: "Required scope or deployment policy denied"
  defp error_description(404), do: "Object or operation not found"
  defp error_description(409), do: "Revision, assignment, or idempotency conflict"
  defp error_description(413), do: "Request exceeds the bounded body size"
  defp error_description(422), do: "Business validation failed"
  defp error_description(429), do: "Request admission limit reached"
  defp error_description(503), do: "Database or adapter unavailable"
end
