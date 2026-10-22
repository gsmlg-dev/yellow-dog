defmodule YellowDog.Management.AuditContext do
  @moduledoc false
  @fields ~w(id worker_id service_id zone_id resource_version_id revision expected_revision
    digest key task_key state status code expected_assignment_token assignment_token deleted)
  def project(value) when is_map(value) do
    safe = Map.take(value, @fields)

    case value["error"] do
      error when is_map(error) -> Map.put(safe, "error", Map.take(error, ~w(code)))
      _ -> safe
    end
  end

  def project(_), do: %{}
end
