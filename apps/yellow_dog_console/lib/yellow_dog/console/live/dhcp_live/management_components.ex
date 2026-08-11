defmodule YellowDog.Console.DhcpLive.ManagementComponents do
  @moduledoc false

  use YellowDog.Console, :html

  alias YellowDog.Console.Components.PoolFormComponent
  alias YellowDog.Console.DhcpLive.ManagementSupport

  attr :management_error, :any, default: nil
  attr :cached_observed_at, :any, default: nil

  def notice(assigns) do
    ~H"""
    <div :if={@cached_observed_at} class="alert alert-warning" role="status">
      <.dm_mdi name="database-clock" class="h-5 w-5 shrink-0" />
      <span>
        Offline cached snapshot · Observed {ManagementSupport.format_observed_at(@cached_observed_at)}
      </span>
    </div>
    <div :if={@management_error} class="alert alert-error" role="alert">
      <.dm_mdi name="alert-circle-outline" class="h-5 w-5 shrink-0" />
      <span>{@management_error.message}</span>
    </div>
    """
  end

  attr :selected_server, :map, required: true
  attr :family_label, :string, required: true
  attr :service_running, :boolean, required: true
  attr :base_path, :string, required: true
  attr :leases_path, :string, required: true
  attr :pools_path, :string, required: true
  attr :activity_path, :string, required: true
  attr :pools, :list, required: true
  attr :leases, :list, required: true
  attr :activities, :list, required: true
  attr :management_error, :any, default: nil
  attr :cached_observed_at, :any, default: nil

  def overview(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div class="space-y-6" id="server-dhcp-overview">
        <.notice
          management_error={@management_error}
          cached_observed_at={@cached_observed_at}
        />
        <div class="flex items-center justify-between gap-4">
          <div>
            <h1 class="text-4xl font-bold">{@family_label} Server</h1>
            <p class="mt-2 text-on-surface-variant">
              {@selected_server.name || @selected_server.id}
            </p>
          </div>
          <.status_indicator
            status={if @service_running, do: "running", else: "stopped"}
            label={if @service_running, do: "Running", else: "Stopped"}
          />
        </div>

        <div class="grid grid-cols-1 gap-4 md:grid-cols-3">
          <.link navigate={@leases_path} class="card card-bordered bg-surface">
            <div class="card-body">
              <div class="text-sm text-on-surface-variant">Leases</div>
              <div class="text-2xl font-bold">{length(@leases)}</div>
            </div>
          </.link>
          <.link navigate={@pools_path} class="card card-bordered bg-surface">
            <div class="card-body">
              <div class="text-sm text-on-surface-variant">Pools</div>
              <div class="text-2xl font-bold">{length(@pools)}</div>
            </div>
          </.link>
          <.link navigate={@activity_path} class="card card-bordered bg-surface">
            <div class="card-body">
              <div class="text-sm text-on-surface-variant">Recent activity</div>
              <div class="text-2xl font-bold">{length(@activities)}</div>
            </div>
          </.link>
        </div>

        <.card title="Address pools">
          <div :if={@pools == []} class="text-on-surface-variant">No pools reported</div>
          <div :for={pool <- @pools} class="py-2">
            <div class="font-semibold">{pool.name}</div>
            <div class="font-mono text-sm text-on-surface-variant">{pool.network}</div>
          </div>
        </.card>

        <.card title="Leases">
          <div :if={@leases == []} class="text-on-surface-variant">No leases reported</div>
          <div :for={lease <- @leases} class="py-2">
            <span class="font-mono">{lease.lease_id}</span>
            <span class="ml-2 text-on-surface-variant">{lease.address}</span>
          </div>
        </.card>

        <.card title="Activity">
          <div :if={@activities == []} class="text-on-surface-variant">No activity reported</div>
          <div :for={entry <- @activities} class="py-2">
            <span class="font-mono">{entry.activity_id}</span>
            <span class="ml-2 text-on-surface-variant">{entry.action}</span>
          </div>
        </.card>
      </div>
    </Layouts.app>
    """
  end

  attr :selected_server, :map, required: true
  attr :family_label, :string, required: true
  attr :base_path, :string, required: true
  attr :leases, :list, required: true
  attr :search_query, :string, required: true
  attr :filter_state, :string, required: true
  attr :commands_enabled?, :boolean, required: true
  attr :management_error, :any, default: nil
  attr :cached_observed_at, :any, default: nil

  def leases(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div class="space-y-6" id="server-dhcp-leases">
        <.notice
          management_error={@management_error}
          cached_observed_at={@cached_observed_at}
        />
        <div class="flex items-center justify-between gap-4">
          <div>
            <h1 class="text-4xl font-bold">{@family_label} Leases</h1>
            <p class="mt-2 text-on-surface-variant">
              {@selected_server.name || @selected_server.id}
            </p>
          </div>
          <.link navigate={@base_path} class="btn btn-ghost btn-sm">
            <.dm_mdi name="arrow-left" class="h-4 w-4" /> Back to Overview
          </.link>
        </div>

        <.card>
          <div class="flex flex-col gap-4 md:flex-row">
            <input
              type="text"
              name="search"
              value={@search_query}
              phx-change="search"
              phx-debounce="300"
              aria-label={"Search #{@family_label} leases"}
              placeholder="Search by lease ID or address"
              class="input w-full"
            />
            <select
              name="state"
              value={@filter_state}
              phx-change="filter_state"
              aria-label="Filter by lease state"
              class="select"
            >
              <option value="all">All states</option>
              <option value="active">Active</option>
              <option value="released">Released</option>
              <option value="expired">Expired</option>
            </select>
          </div>
        </.card>

        <.card title={"Leases (#{length(@leases)})"}>
          <div class="overflow-x-auto">
            <table class="table table-striped">
              <thead>
                <tr>
                  <th>Lease ID</th><th>Address</th><th>State</th><th>Actions</th>
                </tr>
              </thead>
              <tbody>
                <tr :if={@leases == []}>
                  <td colspan="4" class="py-8 text-center text-on-surface-variant">
                    No leases found
                  </td>
                </tr>
                <tr :for={lease <- @leases}>
                  <td class="font-mono">{lease.lease_id}</td>
                  <td class="font-mono">{lease.address}</td>
                  <td>
                    <.badge color={state_color(lease.state)}>{lease.state}</.badge>
                  </td>
                  <td>
                    <button
                      :if={lease.state == "active"}
                      class="btn btn-error btn-xs"
                      phx-click="release_lease"
                      phx-value-lease-id={lease.lease_id}
                      disabled={not @commands_enabled?}
                    >
                      Release
                    </button>
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

  attr :selected_server, :map, required: true
  attr :family, :atom, required: true
  attr :family_label, :string, required: true
  attr :service_type, :atom, required: true
  attr :base_path, :string, required: true
  attr :pools, :list, required: true
  attr :filter, :string, required: true
  attr :show_form, :boolean, required: true
  attr :form_mode, :atom, required: true
  attr :editing_pool, :any, default: nil
  attr :commands_enabled?, :boolean, required: true
  attr :management_error, :any, default: nil
  attr :cached_observed_at, :any, default: nil

  def pools(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div class="space-y-6" id="server-dhcp-pools">
        <.notice
          management_error={@management_error}
          cached_observed_at={@cached_observed_at}
        />
        <div class="flex items-center justify-between gap-4">
          <div>
            <h1 class="text-4xl font-bold">{@family_label} Address Pools</h1>
            <p class="mt-2 text-on-surface-variant">
              {@selected_server.name || @selected_server.id}
            </p>
          </div>
          <button
            class="btn btn-primary"
            phx-click="show_new_form"
            disabled={not @commands_enabled?}
          >
            <.dm_mdi name="plus" class="h-4 w-4" /> Add Pool
          </button>
        </div>

        <input
          type="text"
          name="filter"
          value={@filter}
          phx-change="filter"
          phx-debounce="300"
          aria-label={"Search #{@family_label} pools"}
          placeholder="Search pools"
          class="input w-full"
        />

        <.card title="Configured pools">
          <div class="overflow-x-auto">
            <table class="table table-striped">
              <thead>
                <tr>
                  <th>Name</th><th>Subnet</th><th>Range</th><th>Lease time</th><th>Actions</th>
                </tr>
              </thead>
              <tbody>
                <tr :if={@pools == []}>
                  <td colspan="5" class="py-8 text-center text-on-surface-variant">
                    No address pools
                  </td>
                </tr>
                <tr :for={pool <- @pools}>
                  <td>
                    <.link
                      navigate={pool_path(@selected_server.id, @family, pool.name)}
                      class="link link-primary"
                    >
                      {pool.name}
                    </.link>
                  </td>
                  <td class="font-mono">{pool.network}</td>
                  <td class="font-mono">{pool.range_start} – {pool.range_end}</td>
                  <td>{pool.lease_time}s</td>
                  <td>
                    <div class="flex gap-1">
                      <button
                        class="btn btn-ghost btn-xs"
                        phx-click="show_edit_form"
                        phx-value-pool-name={pool.name}
                        disabled={not @commands_enabled?}
                      >Edit</button>
                      <button
                        class="btn btn-ghost btn-xs text-error"
                        phx-click="delete_pool"
                        phx-value-pool-name={pool.name}
                        disabled={not @commands_enabled?}
                      >Delete</button>
                      <button
                        class="btn btn-ghost btn-xs text-error"
                        phx-click="force_delete_pool"
                        phx-value-pool-name={pool.name}
                        disabled={not @commands_enabled?}
                      >Force delete</button>
                    </div>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </.card>

        <div :if={@show_form} class="alert alert-info" role="status">
          <.dm_mdi name="information-outline" class="h-5 w-5 shrink-0" />
          <span>
            Server management stores subnet, range, and one lease duration for each pool.
            Gateway and DNS values are not part of this resource.<span :if={@family == :ipv6}>
              Preferred and valid lifetimes must match.
            </span>
          </span>
        </div>

        <.live_component
          :if={@show_form}
          module={PoolFormComponent}
          id="pool-form"
          mode={@form_mode}
          protocol={@family}
          service_type={@service_type}
          pool={@editing_pool}
          management_fields_only={true}
        />
      </div>
    </Layouts.app>
    """
  end

  attr :selected_server, :map, required: true
  attr :family_label, :string, required: true
  attr :pools_path, :string, required: true
  attr :pool_name, :string, required: true
  attr :pool, :any, default: nil
  attr :management_error, :any, default: nil
  attr :cached_observed_at, :any, default: nil

  def pool(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div class="space-y-6" id="server-dhcp-pool">
        <.notice
          management_error={@management_error}
          cached_observed_at={@cached_observed_at}
        />
        <div class="flex items-center justify-between gap-4">
          <div>
            <h1 class="text-4xl font-bold">{@family_label} Pool: {@pool_name}</h1>
            <p class="mt-2 text-on-surface-variant">
              {@selected_server.name || @selected_server.id}
            </p>
          </div>
          <.link navigate={@pools_path} class="btn btn-ghost">
            <.dm_mdi name="arrow-left" class="h-4 w-4" /> Back to Pools
          </.link>
        </div>

        <.card :if={@pool} title="Pool Configuration">
          <dl class="grid grid-cols-1 gap-4 md:grid-cols-2">
            <div>
              <dt class="text-on-surface-variant">Pool ID</dt><dd class="font-mono">{@pool.name}</dd>
            </div>
            <div>
              <dt class="text-on-surface-variant">Subnet</dt><dd class="font-mono">
                {@pool.network}
              </dd>
            </div>
            <div>
              <dt class="text-on-surface-variant">Start address</dt><dd class="font-mono">
                {@pool.range_start}
              </dd>
            </div>
            <div>
              <dt class="text-on-surface-variant">End address</dt><dd class="font-mono">
                {@pool.range_end}
              </dd>
            </div>
            <div>
              <dt class="text-on-surface-variant">Lease time</dt><dd>{@pool.lease_time}s</dd>
            </div>
          </dl>
        </.card>
        <.card :if={is_nil(@pool)} title="Pool Not Found">
          <p class="text-on-surface-variant">The selected Server did not report this pool.</p>
        </.card>
        <.card title="Lease details unavailable">
          <p class="text-on-surface-variant">
            The approved lease query does not expose a pool association, so this page cannot safely offer pool-scoped lease actions.
          </p>
        </.card>
      </div>
    </Layouts.app>
    """
  end

  attr :selected_server, :map, required: true
  attr :family_label, :string, required: true
  attr :base_path, :string, required: true
  attr :entries, :list, required: true
  attr :search_query, :string, required: true
  attr :filter_type, :string, required: true
  attr :management_error, :any, default: nil
  attr :cached_observed_at, :any, default: nil

  def activity(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div class="space-y-6" id="server-dhcp-activity">
        <.notice
          management_error={@management_error}
          cached_observed_at={@cached_observed_at}
        />
        <div class="flex items-center justify-between gap-4">
          <div>
            <h1 class="text-4xl font-bold">{@family_label} Activity</h1>
            <p class="mt-2 text-on-surface-variant">
              {@selected_server.name || @selected_server.id}
            </p>
          </div>
          <.link navigate={@base_path} class="btn btn-ghost btn-sm">
            <.dm_mdi name="arrow-left" class="h-4 w-4" /> Back to Overview
          </.link>
        </div>

        <.card>
          <div class="flex flex-col gap-4 md:flex-row">
            <input
              type="text"
              name="search"
              value={@search_query}
              phx-change="search"
              aria-label={"Search #{@family_label} activity"}
              class="input w-full"
            />
            <select
              name="type"
              value={@filter_type}
              phx-change="filter_type"
              aria-label="Filter by activity type"
              class="select"
            >
              <option value="all">All activity</option>
              <option value="lease_granted">Granted</option>
              <option value="lease_renewed">Renewed</option>
              <option value="lease_released">Released</option>
              <option value="lease_expired">Expired</option>
            </select>
          </div>
        </.card>

        <.card title={"Activity (#{length(@entries)})"}>
          <div class="overflow-x-auto">
            <table class="table table-striped">
              <thead>
                <tr>
                  <th>Activity ID</th><th>Action</th><th>Occurred at</th>
                </tr>
              </thead>
              <tbody>
                <tr :if={@entries == []}>
                  <td colspan="3" class="py-8 text-center text-on-surface-variant">
                    No activity reported
                  </td>
                </tr>
                <tr :for={entry <- @entries}>
                  <td class="font-mono">{entry.activity_id}</td>
                  <td>{entry.action}</td>
                  <td>{entry.occurred_at}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </.card>
      </div>
    </Layouts.app>
    """
  end

  defp state_color("active"), do: "success"
  defp state_color("released"), do: "warning"
  defp state_color("expired"), do: "error"
  defp state_color(_state), do: "ghost"

  defp pool_path(server_id, :ipv4, pool_id),
    do: YellowDog.Console.ServicePaths.server_path(server_id, {:dhcpv4_pool, pool_id})

  defp pool_path(server_id, :ipv6, pool_id),
    do: YellowDog.Console.ServicePaths.server_path(server_id, {:dhcpv6_pool, pool_id})
end
