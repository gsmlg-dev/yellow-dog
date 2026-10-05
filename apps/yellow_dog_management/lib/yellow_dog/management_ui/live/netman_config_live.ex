defmodule YellowDog.ManagementUI.NetmanConfigLive do
  use YellowDog.ManagementUI, :live_view

  alias YellowDog.Management.{Domain, NetmanConfig}
  alias YellowDog.ManagementUI.NetmansLive
  alias YellowDog.ManagementUI.Hooks.CurrentPath

  @default_profile %{
    "profile_id" => "",
    "interface" => "",
    "zone" => "default",
    "autoconnect" => "true",
    "autoconnect_priority" => "0",
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
       node: nil,
       draft: nil,
       scope_error: nil,
       netmans: [],
       versions: [],
       validation: nil,
       editing_profile_id: nil,
       profile_form: to_form(@default_profile, as: "profile")
     )}
  end

  @impl true
  def handle_params(_params, uri, socket) do
    {:noreply, load(socket, CurrentPath.route_path_params(socket, uri)["netman_id"])}
  end

  @impl true
  def handle_event("put_profile", %{"profile" => %{"action" => "validate"} = params}, socket),
    do: handle_event("validate_profile", %{"profile" => params}, socket)

  def handle_event("validate_profile", %{"profile" => params}, socket) when is_map(params) do
    socket = retain_profile_form(socket, params)

    case candidate_profile(socket, params) do
      {:ok, _document} ->
        {:noreply, assign(socket, :validation, "Desired configuration is valid")}

      {:error, message} ->
        {:noreply, socket |> assign(:validation, message) |> put_flash(:error, message)}
    end
  end

  def handle_event("put_profile", %{"profile" => params}, socket) when is_map(params) do
    socket = retain_profile_form(socket, params)

    with :ok <- mutable(socket),
         {:ok, document} <- candidate_profile(socket, params) do
      command(
        socket,
        "update_netman_config",
        %{"document" => document},
        "Desired profile saved; not activated."
      )
    else
      {:error, message} -> failure(socket, message)
    end
  end

  def handle_event("edit_profile", %{"profile_id" => id}, socket) do
    with :ok <- scoped(socket),
         profile when not is_nil(profile) <- find_profile(socket, id) do
      {:noreply,
       assign(socket,
         editing_profile_id: id,
         profile_form: to_form(profile_fields(profile), as: "profile"),
         validation: nil
       )}
    else
      _error -> failure(socket, "Desired profile not found")
    end
  end

  def handle_event("cancel_profile", _params, socket) do
    {:noreply,
     socket
     |> assign(
       editing_profile_id: nil,
       profile_form: to_form(@default_profile, as: "profile"),
       validation: nil
     )
     |> push_event("reset_form", %{id: "netman-profile-form"})}
  end

  def handle_event("delete_profile", %{"profile_id" => id}, socket) do
    with :ok <- mutable(socket),
         profile when not is_nil(profile) <- find_profile(socket, id) do
      document =
        Map.update!(
          socket.assigns.draft["document"],
          "profiles",
          &Enum.reject(&1, fn item -> item["profile_id"] == profile["profile_id"] end)
        )

      command(
        socket,
        "update_netman_config",
        %{"document" => document},
        "Desired profile deleted; runtime unchanged."
      )
    else
      {:error, message} -> failure(socket, message)
      _error -> failure(socket, "Desired profile not found")
    end
  end

  def handle_event("update_resolved", %{"resolved" => params}, socket) when is_map(params) do
    socket =
      assign(
        socket,
        :resolved_form,
        to_form(safe_fields(params, %{"upstreams" => "", "search_domains" => ""}), as: "resolved")
      )

    with :ok <- mutable(socket),
         true <- Enum.all?(~w(upstreams search_domains), &is_binary(params[&1])),
         document =
           Map.put(socket.assigns.draft["document"], "resolved", %{
             "upstreams" => csv(params["upstreams"]),
             "search_domains" => csv(params["search_domains"])
           }),
         {:ok, normalized} <- NetmanConfig.validate(document) do
      command(
        socket,
        "update_netman_config",
        %{"document" => normalized},
        "Desired Resolved configuration saved; runtime unchanged."
      )
    else
      false -> failure(socket, "Resolved lists must be comma-separated text")
      {:error, error} -> failure(socket, error_message(error))
    end
  end

  def handle_event("confirm_config", _params, socket) do
    command(
      socket,
      "confirm_netman_config",
      %{},
      "Immutable desired version prepared; not applied to a Netman."
    )
  end

  def handle_event("rollback_config", %{"rollback" => %{"target_version" => target}}, socket) do
    with :ok <- mutable(socket),
         {:ok, version} <- version_number(target),
         true <- Enum.any?(socket.assigns.versions, &(&1["version"] == version)) do
      command(
        socket,
        "rollback_netman_config",
        %{"target_version" => version},
        "Desired rollback prepared as a new immutable version; runtime unchanged."
      )
    else
      {:error, message} -> failure(socket, message)
      false -> failure(socket, "Netman configuration version not found")
    end
  end

  def handle_event("refresh_config", _params, socket) do
    with :ok <- scoped(socket) do
      {:noreply, load(socket, socket.assigns.node["id"])}
    else
      {:error, message} -> failure(socket, message)
    end
  end

  def handle_event(_event, _params, socket),
    do: failure(socket, "Invalid Netman configuration form")

  defp load(socket, id) do
    socket = assign(socket, :netmans, Domain.list_netmans())

    with true <- ServicePaths.valid_netman_id?(id),
         {:ok, node} <- Domain.get_netman(id),
         {:ok, draft} <- Domain.get_netman_config(id) do
      resolved = draft["document"]["resolved"]

      assign(socket,
        node: node,
        draft: draft,
        scope_error: nil,
        page_title:
          if(socket.assigns.live_action == :resolved,
            do: "Resolved",
            else: "Netman Configuration"
          ),
        versions: Domain.list_netman_versions(id),
        validation: nil,
        editing_profile_id: nil,
        profile_form: to_form(@default_profile, as: "profile"),
        resolved_form:
          to_form(
            %{
              "upstreams" => Enum.join(resolved["upstreams"], ", "),
              "search_domains" => Enum.join(resolved["search_domains"], ", ")
            },
            as: "resolved"
          ),
        rollback_form: to_form(%{"target_version" => ""}, as: "rollback")
      )
    else
      false ->
        assign(socket, node: nil, draft: nil, scope_error: "Invalid Netman ID")

      {:error, error} ->
        assign(socket, node: nil, draft: nil, scope_error: NetmansLive.message(error))
    end
  end

  defp scoped(%{assigns: %{node: nil}}), do: {:error, "Netman not found"}
  defp scoped(%{assigns: %{draft: nil}}), do: {:error, "Netman configuration not found"}
  defp scoped(_socket), do: :ok

  defp mutable(socket) do
    with :ok <- scoped(socket) do
      if socket.assigns.node["apply_mode"] == "observe",
        do: {:error, "Observe mode is read-only"},
        else: :ok
    end
  end

  defp command(socket, operation, params, success) do
    with :ok <- mutable(socket) do
      params =
        Map.merge(params, %{
          "id" => socket.assigns.node["id"],
          "expected_revision" => socket.assigns.draft["revision"]
        })

      case Domain.mutate(operation, params, "operator", Ecto.UUID.generate()) do
        {:ok, _result} ->
          {:noreply,
           socket
           |> load(socket.assigns.node["id"])
           |> put_flash(:info, success)
           |> push_event("reset_form", %{id: "netman-profile-form"})}

        {:error, error} ->
          failure(socket, NetmansLive.message(error))
      end
    else
      {:error, message} -> failure(socket, message)
    end
  end

  defp failure(socket, message), do: {:noreply, put_flash(socket, :error, message)}
  defp error_message(error) when is_binary(error), do: error
  defp error_message(error), do: NetmansLive.message(error)

  defp candidate_profile(socket, params) do
    with :ok <- scoped(socket),
         {:ok, profile} <- parse_profile(params),
         :ok <- editing_identity(socket, profile["profile_id"]),
         profiles = replace_profile(socket, profile),
         {:ok, document} <-
           NetmanConfig.validate(Map.put(socket.assigns.draft["document"], "profiles", profiles)) do
      {:ok, document}
    else
      {:error, error} -> {:error, error_message(error)}
    end
  end

  defp editing_identity(%{assigns: %{editing_profile_id: nil}}, _id), do: :ok

  defp editing_identity(%{assigns: %{editing_profile_id: id}} = socket, id) do
    if find_profile(socket, id), do: :ok, else: {:error, "Desired profile not found"}
  end

  defp editing_identity(_socket, _id),
    do: {:error, "Editing cannot change the selected profile ID"}

  defp replace_profile(socket, profile) do
    profiles = socket.assigns.draft["document"]["profiles"]

    case socket.assigns.editing_profile_id do
      nil ->
        profiles ++ [profile]

      id ->
        Enum.map(profiles, fn existing ->
          if existing["profile_id"] == id, do: profile, else: existing
        end)
    end
  end

  defp find_profile(socket, id) when is_binary(id),
    do: Enum.find(socket.assigns.draft["document"]["profiles"], &(&1["profile_id"] == id))

  defp find_profile(_socket, _id), do: nil

  defp parse_profile(params) do
    with true <- Enum.all?(Map.keys(@default_profile), &is_binary(params[&1])),
         true <- params["autoconnect"] in ["true", "false"],
         {:ok, priority} <- integer(params["autoconnect_priority"]),
         {:ok, mtu} <- optional_integer(params["mtu"]) do
      {:ok,
       %{
         "profile_id" => params["profile_id"],
         "type" => "ethernet",
         "interface" => nullable(params["interface"]),
         "zone" => params["zone"],
         "autoconnect" => params["autoconnect"] == "true",
         "autoconnect_priority" => priority,
         "ethernet" => %{"mtu" => mtu},
         "ipv4" => ip_fields(params, "ipv4"),
         "ipv6" => ip_fields(params, "ipv6")
       }}
    else
      false -> {:error, "Profile fields must be text; autoconnect must be true or false"}
      {:error, message} -> {:error, message}
    end
  end

  defp ip_fields(params, family) do
    %{
      "method" => params["#{family}_method"],
      "address" => nullable(params["#{family}_address"]),
      "gateway" => nullable(params["#{family}_gateway"]),
      "dns" => csv(params["#{family}_dns"]),
      "dns_search" => csv(params["#{family}_dns_search"])
    }
  end

  defp profile_fields(profile) do
    fields = %{
      "profile_id" => profile["profile_id"],
      "interface" => profile["interface"] || "",
      "zone" => profile["zone"],
      "autoconnect" => to_string(profile["autoconnect"]),
      "autoconnect_priority" => to_string(profile["autoconnect_priority"]),
      "mtu" => if(profile["ethernet"]["mtu"], do: to_string(profile["ethernet"]["mtu"]), else: "")
    }

    Enum.reduce(~w(ipv4 ipv6), fields, fn family, values ->
      config = profile[family]

      Map.merge(values, %{
        "#{family}_method" => config["method"],
        "#{family}_address" => config["address"] || "",
        "#{family}_gateway" => config["gateway"] || "",
        "#{family}_dns" => Enum.join(config["dns"], ", "),
        "#{family}_dns_search" => Enum.join(config["dns_search"], ", ")
      })
    end)
  end

  defp retain_profile_form(socket, params),
    do:
      assign(socket, :profile_form, to_form(safe_fields(params, @default_profile), as: "profile"))

  defp safe_fields(params, defaults),
    do:
      Map.new(defaults, fn {key, default} ->
        {key, if(is_binary(params[key]), do: params[key], else: default)}
      end)

  defp csv(value),
    do:
      value
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

  defp nullable(value), do: if(String.trim(value) == "", do: nil, else: String.trim(value))

  defp optional_integer(value),
    do: if(String.trim(value) == "", do: {:ok, nil}, else: integer(value))

  defp integer(value) do
    case Integer.parse(value) do
      {number, ""} -> {:ok, number}
      _invalid -> {:error, "Priority and MTU must be integers"}
    end
  end

  defp version_number(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number > 0 -> {:ok, number}
      _invalid -> {:error, "Select a stored configuration version"}
    end
  end

  defp version_number(_value), do: {:error, "Select a stored configuration version"}

  attr :form, :any, required: true
  attr :field, :string, required: true
  attr :label, :string, required: true
  attr :readonly, :boolean, default: false
  attr :disabled, :boolean, default: false

  defp text_field(assigns) do
    ~H"""
    <label class="form-control"><span class="label">{@label}</span><input
      class="input input-bordered"
      name={"#{@form.name}[#{@field}]"}
      value={@form.params[@field]}
      readonly={@readonly}
      disabled={@disabled}
    /></label>
    """
  end

  attr :form, :any, required: true
  attr :field, :string, required: true
  attr :label, :string, required: true
  attr :options, :list, required: true
  attr :disabled, :boolean, default: false

  defp select_field(assigns) do
    ~H"""
    <label class="form-control"><span class="label">{@label}</span><select
      class="select select-bordered"
      name={"#{@form.name}[#{@field}]"}
      disabled={@disabled}
    >
      <option :for={option <- @options} value={option} selected={option == @form.params[@field]}>
        {option}
      </option>
    </select></label>
    """
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns, :read_only, is_nil(assigns.node) or assigns.node["apply_mode"] == "observe")

    ~H"""
    <Layouts.app
      flash={@flash}
      current_path={@current_path}
      netmans={Enum.map(@netmans, &%{id: &1["id"], name: &1["name"]})}
    >
      <div :if={@scope_error} id="netman-config-scope-error" role="alert">{@scope_error}</div>
      <div :if={@node && @draft} class="max-w-7xl space-y-6" id="netman-configuration">
        <div>
          <h1 class="text-3xl font-bold">{@page_title}</h1><p>
            {@node["name"]} · {@node["id"]} · Desired revision {@draft["revision"]}
          </p>
          <p>
            Actual runtime state is unknown. Runtime activation, cache flush and lease operations are not migrated
          </p>
          <p :if={@read_only} class="text-warning">Observe mode is read-only</p>
          <div class="flex flex-wrap gap-2 mt-4">
            <.link navigate={ServicePaths.netman_path(@node["id"], :overview)} class="btn btn-ghost">Overview</.link>
            <.link navigate={ServicePaths.netman_path(@node["id"], :config)} class="btn btn-ghost">Configuration</.link>
            <.link navigate={ServicePaths.netman_path(@node["id"], :resolved)} class="btn btn-ghost">Resolved</.link>
            <button class="btn btn-secondary" phx-click="refresh_config">Refresh Desired State</button>
          </div>
        </div>
        <.card :if={@live_action != :resolved} title="Desired Ethernet Profiles">
          <p :if={@draft["document"]["profiles"] == []}>No desired profiles configured</p>
          <div class="overflow-x-auto">
            <table class="table table-striped" id="netman-desired-profiles">
              <thead>
                <tr>
                  <th>Profile</th><th>Interface</th><th>Zone</th><th>Autoconnect</th><th>IPv4</th><th>
                    IPv6
                  </th><th>Actions</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={profile <- @draft["document"]["profiles"]}>
                  <td>{profile["profile_id"]}</td><td>{profile["interface"] || "Unspecified"}</td><td>
                    {profile["zone"]}
                  </td><td>{to_string(profile["autoconnect"])}</td><td>
                    {profile["ipv4"]["method"]} {profile["ipv4"]["address"]}
                  </td><td>{profile["ipv6"]["method"]} {profile["ipv6"]["address"]}</td>
                  <td>
                    <button
                      class="btn btn-secondary btn-sm"
                      phx-click="edit_profile"
                      phx-value-profile_id={profile["profile_id"]}
                    >Edit</button>
                    <button
                      class="btn btn-error btn-sm"
                      phx-click="delete_profile"
                      phx-value-profile_id={profile["profile_id"]}
                      disabled={@read_only}
                      data-confirm="Delete this desired profile? No runtime interface will be changed."
                    >Delete</button>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </.card>
        <.card
          :if={@live_action != :resolved}
          title={if @editing_profile_id, do: "Edit Ethernet Profile", else: "Create Ethernet Profile"}
        >
          <.form
            for={@profile_form}
            id="netman-profile-form"
            phx-submit="put_profile"
            phx-hook="ResetForm"
            class="space-y-4"
          >
            <.text_field
              form={@profile_form}
              field="profile_id"
              label="Profile ID"
              readonly={not is_nil(@editing_profile_id)}
            />
            <p class="text-sm text-on-surface-variant">
              Type: Ethernet. This form edits desired configuration only.
            </p>
            <.text_field form={@profile_form} field="interface" label="Interface" />
            <.text_field form={@profile_form} field="zone" label="Zone" />
            <.select_field
              form={@profile_form}
              field="autoconnect"
              label="Autoconnect"
              options={~w(true false)}
            />
            <.text_field
              form={@profile_form}
              field="autoconnect_priority"
              label="Autoconnect Priority"
            />
            <.text_field form={@profile_form} field="mtu" label="Ethernet MTU (optional)" />
            <fieldset :for={family <- ~w(ipv4 ipv6)} class="space-y-3">
              <legend class="font-semibold">{if family == "ipv4", do: "IPv4", else: "IPv6"}</legend>
              <.select_field
                form={@profile_form}
                field={"#{family}_method"}
                label="Method"
                options={
                  if family == "ipv4",
                    do: ~w(auto manual disabled),
                    else: ~w(auto manual disabled link-local)
                }
              />
              <.text_field form={@profile_form} field={"#{family}_address"} label="Address (CIDR)" />
              <.text_field form={@profile_form} field={"#{family}_gateway"} label="Gateway" />
              <.text_field
                form={@profile_form}
                field={"#{family}_dns"}
                label="DNS Servers (comma-separated)"
              />
              <.text_field
                form={@profile_form}
                field={"#{family}_dns_search"}
                label="Search Domains (comma-separated)"
              />
            </fieldset>
            <p class="text-sm text-on-surface-variant">
              Manual addressing requires a CIDR address. Disabled families cannot contain address, gateway or DNS settings; IPv6 link-local cannot contain a static address or gateway.
            </p>
            <div class="flex flex-wrap gap-2">
              <button
                type="submit"
                class="btn btn-primary"
                disabled={@read_only}
                phx-disable-with="Saving…"
              >Save Desired Profile</button>
              <button type="submit" class="btn btn-secondary" name="profile[action]" value="validate">Validate</button>
              <button
                :if={@editing_profile_id}
                type="button"
                class="btn btn-ghost"
                phx-click="cancel_profile"
              >Cancel Edit</button>
            </div>
          </.form>
          <p :if={@validation} id="netman-config-validation" role="status" class="mt-4">
            {@validation}
          </p>
        </.card>
        <.card :if={@live_action == :resolved} title="Desired Resolved Configuration">
          <.form
            for={@resolved_form}
            id="netman-resolved-form"
            phx-submit="update_resolved"
            class="space-y-4"
          >
            <.text_field
              form={@resolved_form}
              field="upstreams"
              label="Upstream DNS Servers (comma-separated)"
              disabled={@read_only}
            />
            <.text_field
              form={@resolved_form}
              field="search_domains"
              label="Search Domains (comma-separated)"
              disabled={@read_only}
            />
            <button
              type="submit"
              class="btn btn-primary"
              disabled={@read_only}
              phx-disable-with="Saving…"
            >Save Desired Resolved Configuration</button>
          </.form>
          <p class="mt-4 text-sm text-on-surface-variant">
            Profiles are preserved. Resolver cache contents, counters and cache flush are not available without runtime support.
          </p>
        </.card>
        <.card title="Immutable Desired Configuration Versions">
          <p>
            Confirmation prepares an immutable full configuration version. Rollback restores stored desired content and prepares a new version. Neither action activates a Netman.
          </p>
          <button
            id="confirm-netman-config"
            class="btn btn-primary mt-4"
            phx-click="confirm_config"
            disabled={@read_only}
          >Confirm Desired Configuration</button>
          <div class="overflow-x-auto">
            <table class="table table-striped" id="netman-config-versions">
              <thead>
                <tr>
                  <th>Version</th><th>Source Revision</th><th>Operation</th><th>
                    Status / Actual State
                  </th><th>Digest</th><th>Created</th><th>Content</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={version <- @versions}>
                  <td>{version["version"]}</td><td>{version["source_revision"]}</td><td>
                    {version["operation"]}
                    <div :if={version["rollback_source_id"]}>
                      Rollback source: {version["rollback_source_id"]}
                    </div>
                  </td>
                  <td>{version["status"]} / {version["actual_state"]}</td><td>
                    <code>{version["digest"]}</code>
                  </td><td>{version["inserted_at"]}</td>
                  <td>
                    <details>
                      <summary>Desired document</summary><pre>{Jason.encode!(version["document"], pretty: true)}</pre>
                    </details>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
          <p :if={@versions == []}>No immutable desired versions prepared</p>
          <.form
            for={@rollback_form}
            id="netman-config-rollback-form"
            phx-submit="rollback_config"
            class="space-y-3 mt-4"
          >
            <label class="form-control"><span class="label">Stored Desired Version</span><select
              class="select select-bordered"
              name="rollback[target_version]"
              disabled={@read_only || @versions == []}
              required
            >
              <option value="">Select a version</option><option
                :for={version <- @versions}
                value={version["version"]}
              >
                Version {version["version"]} · Revision {version["source_revision"]}
              </option>
            </select></label>
            <button
              id="rollback-netman-config"
              type="submit"
              class="btn btn-warning"
              disabled={@read_only || @versions == []}
              data-confirm="Restore this stored desired configuration and prepare a new version? No runtime activation will occur."
            >Prepare Desired Rollback</button>
          </.form>
        </.card>
      </div>
    </Layouts.app>
    """
  end
end
