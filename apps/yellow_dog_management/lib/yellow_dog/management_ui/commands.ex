defmodule YellowDog.ManagementUI.Commands do
  @moduledoc "UI commands use the same authorization/receipt boundary without HTTP self-calls."
  alias YellowDog.Management.{Access, ApplicationAPI, Caller, Domain, WorkerConnections}

  @remote %{
    "update_worker" => "worker_update",
    "create_service" => "service_create",
    "update_service" => "service_update",
    "create_zone" => "zone_create",
    "update_zone" => "zone_update",
    "delete_zone" => "zone_delete",
    "confirm_zone" => "zone_confirm",
    "set_zone_assignments" => "zone_set_assignments",
    "confirm_target" => "worker_target_publish",
    "create_dns_view" => "dns_view_create",
    "update_dns_view" => "dns_view_update",
    "delete_dns_view" => "dns_view_delete",
    "create_dns_acl" => "dns_acl_create",
    "update_dns_acl" => "dns_acl_update",
    "delete_dns_acl" => "dns_acl_delete",
    "update_task" => "task_update",
    "run_task" => "ip_database_sync"
  }
  @administrative ~w(set_worker_enrollment create_backup delete_backup)

  def command(socket, operation, params, key) do
    caller = socket.assigns.caller

    cond do
      operation in ["update_task", "run_task"] and params["key"] not in ["ip_city", "ip_country"] ->
        administrative(caller, operation, params, key)

      Map.has_key?(@remote, operation) ->
        ApplicationAPI.ui_command(caller, @remote[operation], params, key)

      operation in @administrative ->
        administrative(caller, operation, params, key)

      true ->
        {:error, %{code: "forbidden", message: "UI operation is not supported"}}
    end
  end

  def create_worker(socket, name) do
    with :ok <- Access.ui_admin(socket.assigns.caller),
         do: WorkerConnections.create(name, socket.assigns.caller)
  end

  def rotate_worker(socket, id) do
    with :ok <- Access.ui_admin(socket.assigns.caller),
         do: WorkerConnections.rotate(id, socket.assigns.caller)
  end

  defp administrative(caller, operation, params, key) do
    with :ok <- Access.ui_admin(caller), {:ok, key} <- Caller.request_key(caller, key) do
      Domain.mutate(operation, params, Caller.actor(caller), key,
        caller: caller,
        scope: "ui:admin",
        context: Caller.audit_context(caller)
      )
    end
  end
end
