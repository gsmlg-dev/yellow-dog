defmodule YellowDog.ManagementUI.EventsLive do
  use YellowDog.ManagementUI, :live_view

  alias YellowDog.Management.Domain

  @worker_operations ~w(create_worker update_worker put_service assign unassign confirm_target create_dns_acl update_dns_acl delete_dns_acl create_dns_view update_dns_view delete_dns_view)
  @netman_operations ~w(create_netman update_netman update_netman_config confirm_netman_config rollback_netman_config)

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(:page_title, "Management Events") |> refresh()}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, refresh(socket)}
  end

  def handle_event("show", %{"id" => id}, socket) do
    {:noreply, assign(socket, :selected, Enum.find(socket.assigns.events, &(&1["id"] == id)))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div class="max-w-7xl space-y-6">
        <div class="flex flex-wrap justify-between gap-4">
          <div>
            <h1 class="text-3xl font-bold">Management Events</h1><p class="text-on-surface-variant">
              Showing the latest 100 retained audit records. These are durable desired-state
              transactions, not Worker or Netman runtime observations.
            </p>
          </div>
          <button
            id="management-events-refresh"
            class="btn btn-outline"
            type="button"
            phx-click="refresh"
          >Refresh</button>
        </div>
        <.card title="Events">
          <p :if={@events == []} class="text-on-surface-variant">No management events yet.</p>
          <div class="overflow-x-auto">
            <table class="table table-striped" id="management-events">
              <thead>
                <tr>
                  <th>Time</th><th>Actor</th><th>Operation</th><th>Details</th>
                </tr>
              </thead><tbody>
                <tr :for={event <- @events}>
                  <td>{event["inserted_at"]}</td><td>{event["actor"]}</td><td>
                    {event["operation"]}
                  </td><td>
                    <button
                      class="btn btn-ghost btn-sm"
                      type="button"
                      phx-click="show"
                      phx-value-id={event["id"]}
                    >Details</button>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </.card>
        <section
          :for={
            {group, label, events} <- [
              {"worker", "Worker", @worker_events},
              {"netman", "Netman", @netman_events}
            ]
          }
          id={"management-#{group}-events"}
        >
          <.card title={"#{label} desired events"}>
            <p :if={events == []} class="text-on-surface-variant">
              No {label} desired events in this audit view.
            </p>
            <.table id={"management-#{group}-events-list"} rows={events} zebra>
              <:col :let={event} label="Time">{event["inserted_at"]}</:col>
              <:col :let={event} label="Actor">{event["actor"]}</:col>
              <:col :let={event} label="Operation">{event["operation"]}</:col>
              <:col :let={event} label="Target">{target_identity(event)}</:col>
              <:col :let={event} label="Details">
                <button
                  class="btn btn-ghost btn-sm"
                  type="button"
                  phx-click="show"
                  phx-value-id={event["id"]}
                >Details</button>
              </:col>
            </.table>
          </.card>
        </section>
        <.card title="Command outcomes">
          <p class="text-on-surface-variant">
            Committed and rejected describe PostgreSQL transaction outcomes only;
            not delivered/applied, remote or job-executor outcomes. A committed enqueue does not
            mean its job has completed. Not all attempted or rejected requests are persisted.
            Global Zone, task and backup events remain in the all-audit and outcome views.
          </p>
          <p :if={@events == []} class="text-on-surface-variant">No retained command outcomes.</p>
          <div class="overflow-x-auto">
            <table class="table table-striped" id="management-command-outcomes">
              <thead>
                <tr>
                  <th>Operation</th><th>Outcome</th><th>Target</th><th>Time</th><th>Error code</th><th>
                    Details
                  </th>
                </tr>
              </thead>
              <tbody>
                <tr
                  :for={event <- @events}
                  data-event-id={event["id"]}
                  data-operation={event["operation"]}
                  data-outcome={outcome(event)}
                >
                  <td>{event["operation"]}</td><td>{outcome(event)}</td><td>
                    {target_identity(event)}
                  </td><td>{event["inserted_at"]}</td><td>{error_code(event)}</td><td>
                    <button
                      class="btn btn-ghost btn-sm"
                      type="button"
                      phx-click="show"
                      phx-value-id={event["id"]}
                    >Details</button>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </.card>
        <.card :if={@selected} title="Event details">
          <pre class="overflow-auto" id="event-details">{Jason.encode!(@selected, pretty: true)}</pre>
        </.card>
      </div>
    </Layouts.app>
    """
  end

  defp refresh(socket) do
    events = Domain.list_audit()

    assign(socket,
      events: events,
      worker_events: Enum.filter(events, &(&1["operation"] in @worker_operations)),
      netman_events: Enum.filter(events, &(&1["operation"] in @netman_operations)),
      selected: nil
    )
  end

  defp failure(event) do
    case event["result"]["error"] do
      %{"code" => code, "message" => message} = error
      when is_binary(code) and is_binary(message) ->
        error

      _ ->
        nil
    end
  end

  defp outcome(event), do: if(failure(event), do: "rejected", else: "committed")
  defp error_code(event), do: if(error = failure(event), do: error["code"], else: "—")

  defp target_identity(event) do
    request = event["request"]
    result = event["result"]

    {scope, identity} =
      case event["operation"] do
        operation when operation in ~w(create_worker update_worker) ->
          {"Worker", result["id"] || request["id"]}

        operation when operation in @worker_operations ->
          {"Worker", result["worker_id"] || request["worker_id"]}

        operation when operation in ~w(create_netman update_netman) ->
          {"Netman", result["id"] || request["id"]}

        operation when operation in @netman_operations ->
          {"Netman", result["netman_id"] || request["id"]}

        "create_zone" ->
          name = if is_map(request["content"]), do: request["content"]["name"]
          {"Zone", result["id"] || request["name"] || name}

        operation when operation in ~w(update_zone delete_zone confirm_zone) ->
          {"Zone", result["zone_id"] || request["id"]}

        operation when operation in ~w(update_task run_task) ->
          {"Task", request["key"]}

        operation when operation in ~w(create_backup delete_backup) ->
          {"Backup", result["id"] || request["id"]}

        _ ->
          {"Global", nil}
      end

    if is_binary(identity) and identity != "",
      do: "#{scope} #{identity}",
      else: "#{scope} (unspecified target)"
  end
end
