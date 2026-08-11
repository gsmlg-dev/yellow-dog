defmodule YellowDog.Console.NetmanLive.DashboardLive do
  @moduledoc """
  Selection landing for registered Netman runtimes.
  """

  use YellowDog.Console, :live_view

  alias YellowDog.Console.ManagementLive.Data

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Select a Netman",
       netmans: Data.list_netmans()
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div class="max-w-7xl space-y-6">
        <div>
          <h1 class="text-3xl font-bold">Select a Netman</h1>
          <p class="mt-1 text-sm text-on-surface-variant">
            Choose the concrete Netman runtime to manage. Offline records remain available for cached reads.
          </p>
        </div>

        <.card title="Registered Netman Instances">
          <div :if={@netmans == []} class="py-10 text-center text-on-surface-variant">
            <.dm_mdi name="lan-disconnect" class="mx-auto mb-3 h-12 w-12" />
            <p class="text-lg">No Netman instances registered</p>
            <p class="mt-1 text-sm">Register a Netman in Management before opening network pages.</p>
          </div>

          <div :if={@netmans != []} class="overflow-x-auto">
            <table class="table table-striped" id="netman-selector-records">
              <thead>
                <tr>
                  <th>Netman</th>
                  <th>Profile</th>
                  <th>Apply Mode</th>
                  <th>Status</th>
                  <th>Last Seen</th>
                  <th class="text-right">Open</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={netman <- @netmans} id={"netman-selector-#{netman.id}"}>
                  <td>
                    <div class="font-semibold">{netman.name || netman.id}</div>
                    <div class="font-mono text-xs text-on-surface-variant">{netman.id}</div>
                  </td>
                  <td>{display_value(netman.profile)}</td>
                  <td>{display_value(netman.apply_mode)}</td>
                  <td>
                    <.badge color={status_color(netman.status)} size="sm">
                      {display_value(netman.status)}
                    </.badge>
                  </td>
                  <td>{format_observed_at(netman.last_seen_at)}</td>
                  <td class="text-right">
                    <.link
                      :if={ServicePaths.valid_netman_id?(netman.id)}
                      navigate={ServicePaths.netman_path(netman.id, :overview)}
                      class="btn btn-primary btn-sm"
                    >
                      Manage
                    </.link>
                    <span
                      :if={not ServicePaths.valid_netman_id?(netman.id)}
                      class="text-xs text-on-surface-variant"
                    >
                      Reserved UI path
                    </span>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </.card>
      </div>
    </Layouts.app>
    """
  end

  defp display_value(nil), do: "-"

  defp display_value(value) when is_atom(value),
    do: value |> Atom.to_string() |> String.replace("_", " ")

  defp display_value(value) when is_binary(value), do: String.replace(value, "_", " ")
  defp display_value(value), do: to_string(value)

  defp status_color(status) when status in [:online, "online"], do: "success"
  defp status_color(status) when status in [:offline, "offline"], do: "ghost"
  defp status_color(_status), do: "info"

  defp format_observed_at(%DateTime{} = observed_at),
    do: Calendar.strftime(observed_at, "%Y-%m-%d %H:%M:%S UTC")

  defp format_observed_at(_observed_at), do: "Never"
end
