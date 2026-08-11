defmodule YellowDog.Console.NetmanLive.ConfigLive do
  @moduledoc """
  Management-owned profile configuration for one selected Netman runtime.
  """

  use YellowDog.Console, :live_view

  alias YellowDog.Console.ManagementResult
  alias YellowDog.Console.NetmanManagement
  alias YellowDog.ManagementCore
  alias YellowDog.Sync.Digest

  @default_profile_form %{
    "profile_id" => "",
    "interface" => "",
    "autoconnect" => "true",
    "autoconnect_priority" => "0",
    "zone" => "default",
    "mtu" => "1500",
    "ipv4_method" => "auto",
    "ipv4_address" => "",
    "ipv4_gateway" => "",
    "ipv4_dns" => "",
    "ipv4_dns_search" => "",
    "ipv6_method" => "auto",
    "ipv6_address" => "",
    "ipv6_gateway" => "",
    "ipv6_dns" => "",
    "ipv6_dns_search" => ""
  }

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Netman Configuration",
       subscribed_netman_id: nil,
       apply_mode: nil,
       profiles: [],
       profiles_revision: nil,
       cached_observed_at: nil,
       management_error: nil,
       config_bootstrap?: false,
       config_read_error?: false,
       observed_profiles: [],
       operation_result: nil,
       profile_form: to_form(@default_profile_form, as: "profile"),
       patch_form:
         to_form(
           %{"profile_id" => "", "field" => "zone", "value" => ""},
           as: "patch"
         ),
       rollback_form: to_form(%{"profile_id" => "", "target_revision" => ""}, as: "rollback"),
       history: nil,
       active_revision: nil,
       config_enabled?: false,
       commands_enabled?: false
     )}
  end

  @impl true
  def handle_params(%{"netman_id" => netman_id}, _uri, socket) do
    socket = subscribe(socket, netman_id)
    {:noreply, if(connected?(socket), do: load_configuration(socket, netman_id), else: socket)}
  end

  @impl true
  def handle_event("validate_profile", %{"profile" => params}, socket) do
    with :ok <- mutable(socket),
         {:ok, profile} <- profile_from_params(params) do
      result =
        NetmanManagement.profiles_validate(selected_id(socket), profile,
          idempotency_key: Ecto.UUID.generate()
        )

      {:noreply, finish(socket, result, "Profile is valid")}
    else
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("put_profile", %{"profile" => %{"action" => "validate"} = params}, socket),
    do: handle_event("validate_profile", %{"profile" => params}, socket)

  def handle_event("put_profile", %{"profile" => params}, socket) do
    with :ok <- configurable(socket),
         {:ok, profile} <- profile_from_params(params) do
      profiles = upsert_desired_profile(socket.assigns.profiles, profile)
      publish_profiles(socket, profiles, "Profile saved")
    else
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("patch_profile", %{"patch" => params}, socket) do
    with :ok <- configurable(socket),
         {:ok, change} <- profile_change(params),
         {:ok, state} <- fetch_profile(socket, params["profile_id"]) do
      profile = apply_profile_change(state["profile"], change)
      profiles = upsert_desired_profile(socket.assigns.profiles, profile)
      publish_profiles(socket, profiles, "Profile patched")
    else
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("delete_profile", %{"profile_id" => profile_id}, socket) do
    with :ok <- configurable(socket),
         {:ok, _state} <- fetch_profile(socket, profile_id) do
      profiles = Enum.reject(socket.assigns.profiles, &(profile_id(&1) == profile_id))
      publish_profiles(socket, profiles, "Profile deleted")
    else
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("activate_profile", %{"profile_id" => profile_id}, socket) do
    with :ok <- mutable(socket),
         {:ok, revision} <- profile_revision(socket, profile_id) do
      result =
        NetmanManagement.profiles_activate(
          selected_id(socket),
          %{"profile_id" => profile_id},
          command_options(revision)
        )

      {:noreply, finish(socket, result, "Profile activated")}
    else
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("rollback_profile", %{"rollback" => params}, socket) do
    with :ok <- mutable(socket),
         {:ok, revision} <- profile_revision(socket, params["profile_id"]) do
      payload = %{
        "profile_id" => params["profile_id"],
        "target_revision" => params["target_revision"]
      }

      result =
        NetmanManagement.profiles_rollback(
          selected_id(socket),
          payload,
          command_options(revision)
        )

      {:noreply, finish(socket, result, "Profile rolled back")}
    else
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("replace_profiles", _params, socket) do
    with :ok <- configurable(socket) do
      publish_profiles(socket, socket.assigns.profiles, "Desired profile set published")
    else
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("load_history", %{"profile_id" => profile_id}, socket) do
    with :ok <- online(socket) do
      result =
        NetmanManagement.profiles_history_list(selected_id(socket), %{"profile_id" => profile_id})

      socket =
        case result do
          %ManagementResult{status: :ok, value: %{"items" => items}} ->
            assign(socket,
              history: %{profile_id: profile_id, items: items},
              operation_result: result
            )

          _result ->
            assign(socket, operation_result: result)
        end

      {:noreply, finish_error(socket, result)}
    else
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("load_active_revision", %{"profile_id" => profile_id}, socket) do
    with :ok <- online(socket) do
      result =
        NetmanManagement.profiles_active_revision_get(
          selected_id(socket),
          %{"profile_id" => profile_id}
        )

      socket =
        case result do
          %ManagementResult{status: :ok, value: value} ->
            assign(socket, active_revision: value, operation_result: result)

          _result ->
            assign(socket, operation_result: result)
        end

      {:noreply, finish_error(socket, result)}
    else
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  @impl true
  def handle_info({:netman_connection, _state, %{netman_id: netman_id}}, socket)
      when netman_id == socket.assigns.selected_netman.id do
    {:noreply, socket |> refresh_selected_netman(netman_id) |> load_configuration(netman_id)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div class="space-y-6" id="netman-configuration">
        <div class="flex items-center justify-between gap-4">
          <div>
            <div class="flex items-center gap-2">
              <.link
                navigate={ServicePaths.netman_path(@selected_netman.id, :overview)}
                class="btn btn-ghost btn-sm btn-circle"
              >
                <.dm_mdi name="arrow-left" class="h-5 w-5" />
              </.link>
              <h1 class="text-4xl font-bold">Netman Configuration</h1>
              <.badge color={if @service_online?, do: "success", else: "ghost"} size="sm">
                {if @service_online?, do: "Connected", else: "Offline"}
              </.badge>
            </div>
            <p class="ml-10 mt-1 text-on-surface-variant">
              {@selected_netman.name || @selected_netman.id} · Apply mode: {display(@apply_mode)}
            </p>
          </div>
          <button
            phx-click="replace_profiles"
            class="btn btn-primary"
            disabled={
              not @config_enabled? or
                (not @config_bootstrap? and not revision_available?(@profiles_revision))
            }
          >
            Publish profile set
          </button>
        </div>

        <.offline_snapshot :if={not @service_online?} observed_at={@cached_observed_at} />

        <div :if={@apply_mode == "observe"} class="alert alert-warning">
          <.dm_mdi name="eye-outline" class="h-5 w-5" />
          <span>Observe mode is read-only. Profile and connection commands are disabled.</span>
        </div>
        <div :if={@apply_mode == "observe_first"} class="alert alert-info">
          <.dm_mdi name="shield-check-outline" class="h-5 w-5" />
          <span>Policy approval is required before observe-first changes are applied.</span>
        </div>

        <.operation_error :if={error_result?(@operation_result)} result={@operation_result} />
        <.operation_error :if={@management_error} result={@management_error} />

        <.card title="Managed profiles">
          <div :if={@profiles == []} class="py-6 text-center text-on-surface-variant">
            No Management-owned profiles.
          </div>
          <div :if={@profiles != []} class="overflow-x-auto">
            <table class="table table-striped" id="managed-netman-profiles">
              <thead>
                <tr>
                  <th>Profile</th>
                  <th>Interface</th>
                  <th>Zone</th>
                  <th>Desired revision</th>
                  <th>State</th>
                  <th class="text-right">Actions</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={state <- @profiles} id={"profile-#{profile_id(state)}"}>
                  <td class="font-semibold">{profile_id(state)}</td>
                  <td class="font-mono text-sm">
                    {get_in(state, ["profile", "interface"]) || "any"}
                  </td>
                  <td>{get_in(state, ["profile", "zone"])}</td>
                  <td class="max-w-48 truncate font-mono text-xs">{state["desired_revision"]}</td>
                  <td>
                    <.badge
                      color={if state["active_revision"], do: "success", else: "ghost"}
                      size="sm"
                    >
                      {if state["active_revision"], do: "active", else: "desired"}
                    </.badge>
                  </td>
                  <td>
                    <div class="flex justify-end gap-1">
                      <button
                        phx-click="load_active_revision"
                        phx-value-profile_id={profile_id(state)}
                        class="btn btn-ghost btn-xs"
                        disabled={not @service_online?}
                      >
                        Revision
                      </button>
                      <button
                        phx-click="load_history"
                        phx-value-profile_id={profile_id(state)}
                        class="btn btn-ghost btn-xs"
                        disabled={not @service_online?}
                      >
                        History
                      </button>
                      <button
                        phx-click="activate_profile"
                        phx-value-profile_id={profile_id(state)}
                        class="btn btn-success btn-xs"
                        disabled={
                          not @commands_enabled? or
                            not revision_available?(state["desired_revision"])
                        }
                      >
                        Activate
                      </button>
                      <button
                        phx-click="delete_profile"
                        phx-value-profile_id={profile_id(state)}
                        class="btn btn-error btn-xs"
                        disabled={not @config_enabled? or not revision_available?(@profiles_revision)}
                      >
                        Delete
                      </button>
                    </div>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </.card>

        <.card
          :if={@config_bootstrap? and @observed_profiles != []}
          title="Observed runtime profiles"
        >
          <div class="overflow-x-auto">
            <table class="table table-striped" id="observed-netman-profiles">
              <thead>
                <tr>
                  <th>Profile</th>
                  <th>Interface</th>
                  <th>Zone</th>
                  <th>State</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={state <- @observed_profiles}>
                  <td class="font-semibold">{profile_id(state)}</td>
                  <td class="font-mono text-sm">
                    {get_in(state, ["profile", "interface"]) || "any"}
                  </td>
                  <td>{get_in(state, ["profile", "zone"])}</td>
                  <td>
                    <.badge color="ghost" size="sm">observed</.badge>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </.card>

        <div class="grid grid-cols-1 gap-6 xl:grid-cols-2">
          <.card title="Validate or save profile">
            <.form
              for={@profile_form}
              id="netman-profile-form"
              phx-submit="put_profile"
              class="space-y-4"
            >
              <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
                <.field field={@profile_form[:profile_id]} label="Profile ID" required />
                <.field field={@profile_form[:interface]} label="Interface" />
                <.field field={@profile_form[:zone]} label="Zone" />
                <.field field={@profile_form[:autoconnect_priority]} label="Priority" type="number" />
                <.field field={@profile_form[:mtu]} label="MTU" type="number" />
              </div>
              <label class="label cursor-pointer justify-start gap-3">
                <input type="hidden" name="profile[autoconnect]" value="false" />
                <input
                  type="checkbox"
                  name="profile[autoconnect]"
                  value="true"
                  checked={@profile_form[:autoconnect].value == "true"}
                  class="checkbox checkbox-primary"
                />
                <span class="label-text">Autoconnect</span>
              </label>
              <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
                <.ip_fields form={@profile_form} family="ipv4" />
                <.ip_fields form={@profile_form} family="ipv6" />
              </div>
              <div class="card-actions justify-end">
                <button
                  type="submit"
                  name="profile[action]"
                  value="validate"
                  class="btn btn-ghost"
                  disabled={not @commands_enabled?}
                >
                  Validate
                </button>
                <button
                  type="submit"
                  class="btn btn-primary"
                  disabled={
                    not @config_enabled? or
                      (not @config_bootstrap? and not revision_available?(@profiles_revision))
                  }
                >
                  Save profile
                </button>
              </div>
            </.form>
          </.card>

          <div class="space-y-6">
            <.card title="Patch profile">
              <.form
                for={@patch_form}
                id="netman-profile-patch"
                phx-submit="patch_profile"
                class="space-y-3"
              >
                <.field field={@patch_form[:profile_id]} label="Profile ID" required />
                <select name="patch[field]" class="select select-bordered w-full">
                  <option value="zone">Zone</option>
                  <option value="interface">Interface</option>
                  <option value="autoconnect_priority">Priority</option>
                  <option value="ethernet.mtu">MTU</option>
                </select>
                <.field field={@patch_form[:value]} label="Value" required />
                <button
                  class="btn btn-primary"
                  disabled={not @config_enabled? or not revision_available?(@profiles_revision)}
                >
                  Apply patch
                </button>
              </.form>
            </.card>

            <.card title="Rollback profile">
              <.form
                for={@rollback_form}
                id="netman-profile-rollback"
                phx-submit="rollback_profile"
                class="space-y-3"
              >
                <.field field={@rollback_form[:profile_id]} label="Profile ID" required />
                <.field field={@rollback_form[:target_revision]} label="Target revision" required />
                <button class="btn btn-warning" disabled={not @commands_enabled?}>Rollback</button>
              </.form>
            </.card>
          </div>
        </div>

        <.card :if={@active_revision} title="Active revision">
          <dl class="grid grid-cols-1 gap-2 sm:grid-cols-3">
            <div>
              <dt class="text-xs text-on-surface-variant">Profile</dt><dd>
                {@active_revision["profile_id"]}
              </dd>
            </div>
            <div>
              <dt class="text-xs text-on-surface-variant">Desired</dt><dd class="font-mono text-xs">
                {@active_revision["desired_revision"]}
              </dd>
            </div>
            <div>
              <dt class="text-xs text-on-surface-variant">Active</dt><dd class="font-mono text-xs">
                {@active_revision["active_revision"] || "not active"}
              </dd>
            </div>
          </dl>
        </.card>

        <.card :if={@history} title="Revision history">
          <div class="mb-2 font-semibold">{@history.profile_id}</div>
          <div
            :for={entry <- @history.items}
            class="border-t border-outline-variant py-3 first:border-0"
          >
            <div class="font-mono text-xs">{entry["revision"]}</div>
            <div class="text-sm text-on-surface-variant">Stored {entry["stored_at"]}</div>
          </div>
        </.card>
      </div>
    </Layouts.app>
    """
  end

  defp field(assigns) do
    assigns = assign_new(assigns, :type, fn -> "text" end)
    assigns = assign_new(assigns, :required, fn -> false end)

    ~H"""
    <label class="form-control">
      <span class="label"><span class="label-text">{@label}</span></span>
      <input
        type={@type}
        name={@field.name}
        value={@field.value}
        required={@required}
        class="input input-bordered w-full"
      />
    </label>
    """
  end

  defp ip_fields(assigns) do
    {method, address, gateway, dns, dns_search} = ip_field_atoms(assigns.family)

    assigns =
      assign(assigns,
        method: method,
        address: address,
        gateway: gateway,
        dns: dns,
        dns_search: dns_search
      )

    ~H"""
    <div class="space-y-3">
      <div class="font-semibold">{String.upcase(@family)}</div>
      <select name={@form[@method].name} class="select select-bordered w-full">
        <option :for={mode <- ip_modes(@family)} value={mode} selected={@form[@method].value == mode}>
          {display(mode)}
        </option>
      </select>
      <.field field={@form[@address]} label="Address" />
      <.field field={@form[@gateway]} label="Gateway" />
      <.field field={@form[@dns]} label="DNS servers (comma separated)" />
      <.field field={@form[@dns_search]} label="Search domains (comma separated)" />
    </div>
    """
  end

  defp offline_snapshot(assigns) do
    ~H"""
    <div class="alert alert-warning" id="offline-snapshot">
      <.dm_mdi name="cloud-off-outline" class="h-5 w-5" />
      <div>
        <div class="font-semibold">Offline cached snapshot</div>
        <div class="text-sm">Observed {format_observed_at(@observed_at)}</div>
      </div>
    </div>
    """
  end

  defp operation_error(assigns) do
    ~H"""
    <div class="alert alert-error" id="management-operation-error">
      <.dm_mdi name="alert-circle" class="h-5 w-5" />
      <div>
        <div>{@result.message}</div>
        <dl :if={@result.code == :conflict} class="mt-2 text-sm">
          <div :for={{key, value} <- Enum.sort(@result.details)}>
            <dt class="inline font-semibold">{detail_label(key)}:</dt>
            <dd class="inline font-mono">{value}</dd>
          </div>
        </dl>
      </div>
    </div>
    """
  end

  defp load_configuration(socket, netman_id) do
    mode_result = NetmanManagement.runtime_apply_mode_get(netman_id)
    profiles_result = NetmanManagement.profiles_list(netman_id)
    profiles_config_result = NetmanManagement.profiles_config(netman_id)
    results = [mode_result, profiles_result, profiles_config_result]
    apply_mode = mode_result |> value(%{}) |> Map.get("mode")
    profile_value = value(profiles_result, %{})
    runtime_profiles = Map.get(profile_value, "items", [])
    runtime_revision = Map.get(profile_value, "revision")

    {profiles, profiles_revision, observed_profiles, config_bootstrap?, config_read_error?} =
      editable_profile_configuration(profiles_config_result, runtime_profiles, runtime_revision)

    service_online? = socket.assigns.service_online?

    assign(socket,
      page_title: "#{socket.assigns.selected_netman.name || netman_id} — Configuration",
      apply_mode: apply_mode,
      profiles: profiles,
      profiles_revision: profiles_revision,
      management_error: first_error(results),
      config_bootstrap?: config_bootstrap?,
      config_read_error?: config_read_error?,
      observed_profiles: observed_profiles,
      cached_observed_at:
        cached_observed_at(results, socket.assigns.selected_netman.last_seen_at),
      config_enabled?: not config_read_error? and apply_mode != "observe",
      commands_enabled?: service_online? and apply_mode != "observe"
    )
  end

  defp editable_profile_configuration(
         %ManagementResult{status: :ok, value: nil},
         runtime_profiles,
         _runtime_revision
       ),
       do: {[], nil, runtime_profiles, true, false}

  defp editable_profile_configuration(
         %ManagementResult{status: :ok, value: managed_config},
         runtime_profiles,
         runtime_revision
       ) do
    {
      editable_profiles(managed_config, runtime_profiles),
      editable_profiles_revision(managed_config, runtime_revision),
      runtime_profiles,
      false,
      false
    }
  end

  defp editable_profile_configuration(
         %ManagementResult{status: :error},
         _runtime_profiles,
         _runtime_revision
       ),
       do: {[], nil, [], false, true}

  defp editable_profiles(%{payload: %{"profiles" => profiles}}, runtime_profiles)
       when is_list(profiles) and is_list(runtime_profiles) do
    Enum.map(profiles, fn profile ->
      case Enum.find(
             runtime_profiles,
             &(get_in(&1, ["profile", "profile_id"]) == profile["profile_id"])
           ) do
        %{"profile" => ^profile} = state -> state
        _stale_or_missing -> desired_profile_state(profile)
      end
    end)
  end

  defp editable_profiles(_managed_config, runtime_profiles) when is_list(runtime_profiles),
    do: runtime_profiles

  defp editable_profiles(_managed_config, _runtime_profiles), do: []

  defp desired_profile_state(profile) do
    %{"profile" => profile, "desired_revision" => nil, "active_revision" => nil}
  end

  defp editable_profiles_revision(%{applied_revision: revision}, _runtime_revision)
       when is_binary(revision),
       do: revision

  defp editable_profiles_revision(%{expected_revision: revision}, _runtime_revision)
       when is_binary(revision),
       do: revision

  defp editable_profiles_revision(_managed_config, runtime_revision), do: runtime_revision

  defp configurable(%{assigns: %{config_read_error?: true}}),
    do: {:error, "Management-owned profile configuration is unavailable"}

  defp configurable(%{assigns: %{apply_mode: "observe"}}),
    do: {:error, "Observe mode is read-only"}

  defp configurable(_socket), do: :ok

  defp online(%{assigns: %{service_online?: false}}),
    do: {:error, "The selected Netman is offline; runtime queries are disabled"}

  defp online(_socket), do: :ok

  defp mutable(%{assigns: %{service_online?: false}}),
    do: {:error, "The selected Netman is offline; commands are disabled"}

  defp mutable(%{assigns: %{apply_mode: "observe"}}),
    do: {:error, "Observe mode is read-only"}

  defp mutable(_socket), do: :ok

  defp profile_from_params(params) do
    with {:ok, priority} <- integer(params["autoconnect_priority"], -1000, 10_000, "priority"),
         {:ok, mtu} <- nullable_integer(params["mtu"], 68, 65_535, "MTU") do
      {:ok,
       %{
         "profile_id" => params["profile_id"],
         "type" => "ethernet",
         "interface" => nullable_text(params["interface"]),
         "autoconnect" => params["autoconnect"] == "true",
         "autoconnect_priority" => priority,
         "zone" => params["zone"],
         "ethernet" => %{"mtu" => mtu},
         "ipv4" => ip_payload(params, "ipv4"),
         "ipv6" => ip_payload(params, "ipv6")
       }}
    end
  end

  defp ip_payload(params, family) do
    %{
      "method" => params["#{family}_method"],
      "address" => nullable_text(params["#{family}_address"]),
      "gateway" => nullable_text(params["#{family}_gateway"]),
      "dns" => csv(params["#{family}_dns"]),
      "dns_search" => csv(params["#{family}_dns_search"])
    }
  end

  defp profile_change(%{"field" => field, "value" => value})
       when field in ["zone", "interface"] do
    {:ok,
     %{
       "field" => field,
       "value" => if(field == "interface", do: nullable_text(value), else: value)
     }}
  end

  defp profile_change(%{"field" => "autoconnect_priority", "value" => value}) do
    with {:ok, value} <- integer(value, -1000, 10_000, "priority") do
      {:ok, %{"field" => "autoconnect_priority", "value" => value}}
    end
  end

  defp profile_change(%{"field" => "ethernet.mtu", "value" => value}) do
    with {:ok, value} <- nullable_integer(value, 68, 65_535, "MTU") do
      {:ok, %{"field" => "ethernet.mtu", "value" => value}}
    end
  end

  defp profile_change(_params), do: {:error, "Unsupported profile patch"}

  defp apply_profile_change(profile, %{"field" => "ethernet.mtu", "value" => value}),
    do: put_in(profile, ["ethernet", "mtu"], value)

  defp apply_profile_change(profile, %{"field" => field, "value" => value}),
    do: Map.put(profile, field, value)

  defp integer(value, minimum, maximum, label) do
    case Integer.parse(to_string(value || "")) do
      {integer, ""} when integer >= minimum and integer <= maximum -> {:ok, integer}
      _invalid -> {:error, "Invalid #{label}"}
    end
  end

  defp nullable_integer(value, _minimum, _maximum, _label) when value in [nil, ""], do: {:ok, nil}

  defp nullable_integer(value, minimum, maximum, label),
    do: integer(value, minimum, maximum, label)

  defp nullable_text(value) when value in [nil, ""], do: nil
  defp nullable_text(value), do: String.trim(value)

  defp csv(value) when value in [nil, ""], do: []

  defp csv(value) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp profile_revision(socket, profile_id) do
    case find_profile(socket, profile_id) do
      nil -> {:error, "The exact profile revision is unavailable"}
      state -> exact_revision(state["desired_revision"], "profile")
    end
  end

  defp fetch_profile(socket, profile_id) do
    case find_profile(socket, profile_id) do
      nil -> {:error, "The selected profile is unavailable"}
      state -> {:ok, state}
    end
  end

  defp find_profile(socket, profile_id) do
    Enum.find(socket.assigns.profiles, &(profile_id(&1) == profile_id))
  end

  defp exact_revision(revision, owner) do
    case Digest.validate(revision) do
      {:ok, revision} -> {:ok, revision}
      _error -> {:error, "The exact #{owner} revision is unavailable"}
    end
  end

  defp revision_available?(revision), do: match?({:ok, _revision}, Digest.validate(revision))

  defp command_options(revision) do
    [
      expected_revision: revision,
      idempotency_key: Ecto.UUID.generate()
    ]
  end

  defp publish_profiles(socket, profiles, success_message) do
    with {:ok, revision} <- publish_revision(socket) do
      payload = %{"profiles" => Enum.map(profiles, & &1["profile"])}

      result =
        NetmanManagement.profiles_replace(
          selected_id(socket),
          payload,
          expected_revision: revision
        )

      socket =
        case result do
          %ManagementResult{status: :ok} -> assign(socket, :profiles, profiles)
          _result -> socket
        end

      {:noreply, finish(socket, result, success_message)}
    else
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  defp publish_revision(%{assigns: %{config_bootstrap?: true}}), do: {:ok, nil}

  defp publish_revision(socket),
    do: exact_revision(socket.assigns.profiles_revision, "profiles collection")

  defp upsert_desired_profile(profiles, profile) do
    id = profile["profile_id"]

    state =
      case Enum.find(profiles, &(profile_id(&1) == id)) do
        nil -> %{"active_revision" => nil}
        state -> state
      end
      |> Map.put("profile", profile)
      |> Map.put("desired_revision", nil)

    [state | Enum.reject(profiles, &(profile_id(&1) == id))]
    |> Enum.sort_by(&profile_id/1)
  end

  defp finish(socket, %ManagementResult{status: :ok} = result, message) do
    socket
    |> assign(operation_result: result)
    |> put_flash(:info, message)
  end

  defp finish(socket, %ManagementResult{} = result, _message) do
    socket
    |> assign(operation_result: result)
    |> finish_error(result)
  end

  defp finish_error(socket, %ManagementResult{status: :error, message: message}),
    do: put_flash(socket, :error, message)

  defp finish_error(socket, _result), do: socket

  defp subscribe(socket, netman_id) do
    if connected?(socket) and socket.assigns.subscribed_netman_id != netman_id do
      if old_id = socket.assigns.subscribed_netman_id do
        Phoenix.PubSub.unsubscribe(YellowDog.Console.PubSub, "management:netman:#{old_id}")
      end

      Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, "management:netman:#{netman_id}")
    end

    assign(socket, :subscribed_netman_id, netman_id)
  end

  defp refresh_selected_netman(socket, netman_id) do
    case ManagementCore.get_netman(netman_id) do
      {:ok, netman} ->
        assign(socket,
          selected_netman: netman,
          service_online?: netman.status in [:online, "online"],
          snapshot_observed_at: netman.last_seen_at
        )

      _error ->
        socket
    end
  end

  defp selected_id(socket), do: socket.assigns.selected_netman.id
  defp profile_id(state), do: get_in(state, ["profile", "profile_id"])

  defp value(%ManagementResult{status: :ok, value: value}, _default), do: value
  defp value(_result, default), do: default

  defp first_error(results) do
    Enum.find_value(results, fn
      %ManagementResult{status: :error} = result -> result
      _result -> nil
    end)
  end

  defp cached_observed_at(results, fallback) do
    Enum.find_value(results, fallback, fn
      %ManagementResult{source: :cache, observed_at: observed_at} -> observed_at
      _result -> nil
    end)
  end

  defp error_result?(%ManagementResult{status: :error}), do: true
  defp error_result?(_result), do: false

  defp detail_label(key), do: key |> String.replace("_", " ") |> String.capitalize()

  defp display(nil), do: "-"
  defp display(value) when is_atom(value), do: value |> Atom.to_string() |> display()
  defp display(value) when is_binary(value), do: String.replace(value, "_", " ")
  defp display(value), do: to_string(value)

  defp ip_modes("ipv4"), do: ["auto", "manual", "disabled"]
  defp ip_modes("ipv6"), do: ["auto", "manual", "link-local", "disabled"]

  defp ip_field_atoms("ipv4"),
    do: {:ipv4_method, :ipv4_address, :ipv4_gateway, :ipv4_dns, :ipv4_dns_search}

  defp ip_field_atoms("ipv6"),
    do: {:ipv6_method, :ipv6_address, :ipv6_gateway, :ipv6_dns, :ipv6_dns_search}

  defp format_observed_at(%DateTime{} = datetime),
    do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S UTC")

  defp format_observed_at(value) when is_binary(value), do: value
  defp format_observed_at(_value), do: "unknown"
end
