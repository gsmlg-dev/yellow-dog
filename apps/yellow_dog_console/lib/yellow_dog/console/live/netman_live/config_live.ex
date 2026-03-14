defmodule YellowDog.Console.NetmanLive.ConfigLive do
  @moduledoc """
  Netman configuration page — documents the TOML profile format and provides
  an interactive form to generate profile configuration files.
  """

  use YellowDog.Console, :live_view

  @file_layout_example """
  # Profile directory (configurable in netman.toml)
  /etc/yellowdog/netman/profiles/
  ├── dhcp-ethernet.toml
  ├── static-ethernet.toml
  └── office-wifi.toml

  # Main netman config
  /etc/yellowdog/netman/netman.toml\
  """

  @netman_toml_example """
  [netman]
  reconciliation_interval_ms = 30000
  reconciliation_debounce_ms = 100
  profile_dir = "/etc/yellowdog/netman/profiles"
  socket_path = "/run/yellowdog/netman.sock"

  [netman.logging]
  level = "info"

  [netman.kernel]
  netlink_helper_path = "priv/native/netlink_helper"\
  """

  @dhcp_example """
  [connection]
  id = "dhcp-ethernet"
  type = "ethernet"
  interface = "eth0"
  autoconnect = true
  autoconnect_priority = 100

  [ethernet]
  mtu = 1500

  [ipv4]
  method = "auto"

  [ipv6]
  method = "auto"\
  """

  @static_example """
  [connection]
  id = "static-ethernet"
  type = "ethernet"
  interface = "eth1"
  autoconnect = false
  autoconnect_priority = 50

  [ethernet]
  mtu = 9000

  [ipv4]
  method = "manual"
  address = "192.168.1.100/24"
  gateway = "192.168.1.1"
  dns = ["192.168.1.1", "8.8.8.8"]

  [ipv6]
  method = "disabled"\
  """

  @default_form %{
    "id" => "",
    "type" => "ethernet",
    "interface" => "",
    "autoconnect" => "true",
    "autoconnect_priority" => "0",
    "zone" => "default",
    "mtu" => "",
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
       page_title: "Configuration",
       form: to_form(@default_form, as: "profile"),
       generated_toml: nil,
       validation_errors: [],
       show_reference: false,
       file_layout_example: @file_layout_example,
       netman_toml_example: @netman_toml_example,
       dhcp_example: @dhcp_example,
       static_example: @static_example
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div class="space-y-6">
        <!-- Header -->
        <div class="flex items-center justify-between">
          <div>
            <h1 class="text-4xl font-bold">Netman Configuration</h1>
            <p class="mt-2 text-on-surface-variant">
              Generate TOML profile files for the Network Manager
            </p>
          </div>
          <button
            phx-click="toggle_reference"
            class={"btn btn-sm " <> if(@show_reference, do: "btn-primary", else: "btn-ghost")}
          >
            <.dm_mdi name="book-open-variant" class="h-4 w-4" />
            <span>Reference</span>
          </button>
        </div>

        <!-- Reference Documentation -->
        <%= if @show_reference do %>
          <div class="card bg-surface shadow-xl">
            <div class="card-body">
              <div class="flex items-center justify-between">
                <h2 class="card-title">Profile TOML Reference</h2>
                <button phx-click="toggle_reference" class="btn btn-ghost btn-sm btn-circle">
                  <.dm_mdi name="close" class="h-5 w-5" />
                </button>
              </div>

              <div class="space-y-4 mt-2">
                <p class="text-on-surface-variant">
                  Netman uses TOML files for connection profiles. Each file defines one network
                  connection and is placed in the profile directory
                  (default: <code class="text-primary">/etc/yellowdog/netman/profiles/</code>).
                </p>

                <div class="divider">File Location</div>
                <div class="bg-surface-container rounded-lg p-4">
                  <pre class="text-sm font-mono text-on-surface"><code>{@file_layout_example}</code></pre>
                </div>

                <div class="divider">netman.toml (Service Config)</div>
                <div class="bg-surface-container rounded-lg p-4">
                  <pre class="text-sm font-mono text-on-surface"><code>{@netman_toml_example}</code></pre>
                </div>

                <div class="divider">Profile TOML Schema</div>
                <div class="overflow-x-auto">
                  <table class="table table-sm">
                    <thead>
                      <tr>
                        <th>Section</th>
                        <th>Key</th>
                        <th>Type</th>
                        <th>Default</th>
                        <th>Description</th>
                      </tr>
                    </thead>
                    <tbody>
                      <tr>
                        <td rowspan="6" class="font-mono text-sm align-top">[connection]</td>
                        <td class="font-mono text-sm">id</td>
                        <td>string</td>
                        <td>
                          <.badge color="error" size="sm">Required</.badge>
                        </td>
                        <td>Unique profile identifier (alphanumeric, _, -, .)</td>
                      </tr>
                      <tr>
                        <td class="font-mono text-sm">type</td>
                        <td>string</td>
                        <td>
                          <.badge color="error" size="sm">Required</.badge>
                        </td>
                        <td>"ethernet" (only supported type)</td>
                      </tr>
                      <tr>
                        <td class="font-mono text-sm">interface</td>
                        <td>string</td>
                        <td>nil</td>
                        <td>Bind to specific interface (e.g. "eth0"), max 15 chars</td>
                      </tr>
                      <tr>
                        <td class="font-mono text-sm">autoconnect</td>
                        <td>boolean</td>
                        <td>true</td>
                        <td>Automatically activate when carrier detected</td>
                      </tr>
                      <tr>
                        <td class="font-mono text-sm">autoconnect_priority</td>
                        <td>integer</td>
                        <td>0</td>
                        <td>Priority for autoconnect (-1000 to 10000, higher wins)</td>
                      </tr>
                      <tr>
                        <td class="font-mono text-sm">zone</td>
                        <td>string</td>
                        <td>"default"</td>
                        <td>Firewall zone assignment</td>
                      </tr>
                      <tr>
                        <td class="font-mono text-sm align-top">[ethernet]</td>
                        <td class="font-mono text-sm">mtu</td>
                        <td>integer</td>
                        <td>nil</td>
                        <td>MTU size (68–65535)</td>
                      </tr>
                      <tr>
                        <td rowspan="5" class="font-mono text-sm align-top">[ipv4]</td>
                        <td class="font-mono text-sm">method</td>
                        <td>string</td>
                        <td>"auto"</td>
                        <td>"auto" (DHCP), "manual" (static), or "disabled"</td>
                      </tr>
                      <tr>
                        <td class="font-mono text-sm">address</td>
                        <td>string</td>
                        <td>nil</td>
                        <td>CIDR address (required if manual, e.g. "192.168.1.10/24")</td>
                      </tr>
                      <tr>
                        <td class="font-mono text-sm">gateway</td>
                        <td>string</td>
                        <td>nil</td>
                        <td>Default gateway IP address</td>
                      </tr>
                      <tr>
                        <td class="font-mono text-sm">dns</td>
                        <td>string[]</td>
                        <td>[]</td>
                        <td>DNS server addresses</td>
                      </tr>
                      <tr>
                        <td class="font-mono text-sm">dns_search</td>
                        <td>string[]</td>
                        <td>[]</td>
                        <td>DNS search domains</td>
                      </tr>
                      <tr>
                        <td rowspan="5" class="font-mono text-sm align-top">[ipv6]</td>
                        <td class="font-mono text-sm">method</td>
                        <td>string</td>
                        <td>"auto"</td>
                        <td>"auto" (SLAAC), "manual", "disabled", or "link-local"</td>
                      </tr>
                      <tr>
                        <td class="font-mono text-sm">address</td>
                        <td>string</td>
                        <td>nil</td>
                        <td>CIDR address (required if manual, e.g. "fd00::1/64")</td>
                      </tr>
                      <tr>
                        <td class="font-mono text-sm">gateway</td>
                        <td>string</td>
                        <td>nil</td>
                        <td>Default gateway IPv6 address</td>
                      </tr>
                      <tr>
                        <td class="font-mono text-sm">dns</td>
                        <td>string[]</td>
                        <td>[]</td>
                        <td>DNS server addresses</td>
                      </tr>
                      <tr>
                        <td class="font-mono text-sm">dns_search</td>
                        <td>string[]</td>
                        <td>[]</td>
                        <td>DNS search domains</td>
                      </tr>
                    </tbody>
                  </table>
                </div>

                <div class="divider">Example: DHCP Ethernet</div>
                <div class="bg-surface-container rounded-lg p-4">
                  <pre class="text-sm font-mono text-on-surface"><code>{@dhcp_example}</code></pre>
                </div>

                <div class="divider">Example: Static Ethernet</div>
                <div class="bg-surface-container rounded-lg p-4">
                  <pre class="text-sm font-mono text-on-surface"><code>{@static_example}</code></pre>
                </div>
              </div>
            </div>
          </div>
        <% end %>

        <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
          <!-- Form -->
          <div class="card bg-surface shadow-xl">
            <div class="card-body">
              <h2 class="card-title">Profile Generator</h2>

              <%= if @validation_errors != [] do %>
                <div class="alert alert-error text-sm">
                  <.dm_mdi name="alert-circle" class="h-5 w-5" />
                  <div>
                    <ul class="list-disc list-inside">
                      <%= for err <- @validation_errors do %>
                        <li>{err}</li>
                      <% end %>
                    </ul>
                  </div>
                </div>
              <% end %>

              <.form for={@form} phx-change="validate" phx-submit="generate" class="space-y-4">
                <!-- Connection Section -->
                <div class="divider text-sm font-semibold">Connection</div>

                <div class="grid grid-cols-2 gap-4">
                  <div class="form-control">
                    <label class="label"><span class="label-text">Profile ID *</span></label>
                    <input
                      type="text"
                      name="profile[id]"
                      value={@form[:id].value}
                      placeholder="my-ethernet"
                      class="input input-bordered w-full"
                      required
                    />
                  </div>
                  <div class="form-control">
                    <label class="label"><span class="label-text">Type</span></label>
                    <select name="profile[type]" class="select select-bordered w-full">
                      <option value="ethernet" selected={@form[:type].value == "ethernet"}>
                        Ethernet
                      </option>
                    </select>
                  </div>
                </div>

                <div class="grid grid-cols-2 gap-4">
                  <div class="form-control">
                    <label class="label"><span class="label-text">Interface</span></label>
                    <input
                      type="text"
                      name="profile[interface]"
                      value={@form[:interface].value}
                      placeholder="eth0 (optional)"
                      class="input input-bordered w-full"
                    />
                  </div>
                  <div class="form-control">
                    <label class="label"><span class="label-text">Zone</span></label>
                    <input
                      type="text"
                      name="profile[zone]"
                      value={@form[:zone].value}
                      placeholder="default"
                      class="input input-bordered w-full"
                    />
                  </div>
                </div>

                <div class="grid grid-cols-2 gap-4">
                  <div class="form-control">
                    <label class="label cursor-pointer justify-start gap-2">
                      <input
                        type="hidden"
                        name="profile[autoconnect]"
                        value="false"
                      />
                      <input
                        type="checkbox"
                        name="profile[autoconnect]"
                        value="true"
                        checked={@form[:autoconnect].value == "true"}
                        class="checkbox checkbox-primary"
                      />
                      <span class="label-text">Autoconnect</span>
                    </label>
                  </div>
                  <div class="form-control">
                    <label class="label"><span class="label-text">Priority</span></label>
                    <input
                      type="number"
                      name="profile[autoconnect_priority]"
                      value={@form[:autoconnect_priority].value}
                      min="-1000"
                      max="10000"
                      class="input input-bordered w-full"
                    />
                  </div>
                </div>

                <!-- Ethernet Section -->
                <div class="divider text-sm font-semibold">Ethernet</div>

                <div class="form-control">
                  <label class="label"><span class="label-text">MTU</span></label>
                  <input
                    type="number"
                    name="profile[mtu]"
                    value={@form[:mtu].value}
                    placeholder="1500 (optional)"
                    min="68"
                    max="65535"
                    class="input input-bordered w-full"
                  />
                </div>

                <!-- IPv4 Section -->
                <div class="divider text-sm font-semibold">IPv4</div>

                <div class="form-control">
                  <label class="label"><span class="label-text">Method</span></label>
                  <select name="profile[ipv4_method]" class="select select-bordered w-full">
                    <option value="auto" selected={@form[:ipv4_method].value == "auto"}>
                      Auto (DHCP)
                    </option>
                    <option value="manual" selected={@form[:ipv4_method].value == "manual"}>
                      Manual (Static)
                    </option>
                    <option value="disabled" selected={@form[:ipv4_method].value == "disabled"}>
                      Disabled
                    </option>
                  </select>
                </div>

                <%= if @form[:ipv4_method].value == "manual" do %>
                  <div class="grid grid-cols-2 gap-4">
                    <div class="form-control">
                      <label class="label"><span class="label-text">Address (CIDR) *</span></label>
                      <input
                        type="text"
                        name="profile[ipv4_address]"
                        value={@form[:ipv4_address].value}
                        placeholder="192.168.1.100/24"
                        class="input input-bordered w-full"
                      />
                    </div>
                    <div class="form-control">
                      <label class="label"><span class="label-text">Gateway</span></label>
                      <input
                        type="text"
                        name="profile[ipv4_gateway]"
                        value={@form[:ipv4_gateway].value}
                        placeholder="192.168.1.1"
                        class="input input-bordered w-full"
                      />
                    </div>
                  </div>
                <% end %>

                <%= if @form[:ipv4_method].value != "disabled" do %>
                  <div class="grid grid-cols-2 gap-4">
                    <div class="form-control">
                      <label class="label">
                        <span class="label-text">DNS Servers</span>
                      </label>
                      <input
                        type="text"
                        name="profile[ipv4_dns]"
                        value={@form[:ipv4_dns].value}
                        placeholder="8.8.8.8, 8.8.4.4"
                        class="input input-bordered w-full"
                      />
                      <label class="label">
                        <span class="label-text-alt text-on-surface-variant">
                          Comma-separated
                        </span>
                      </label>
                    </div>
                    <div class="form-control">
                      <label class="label">
                        <span class="label-text">DNS Search Domains</span>
                      </label>
                      <input
                        type="text"
                        name="profile[ipv4_dns_search]"
                        value={@form[:ipv4_dns_search].value}
                        placeholder="example.com, local"
                        class="input input-bordered w-full"
                      />
                      <label class="label">
                        <span class="label-text-alt text-on-surface-variant">
                          Comma-separated
                        </span>
                      </label>
                    </div>
                  </div>
                <% end %>

                <!-- IPv6 Section -->
                <div class="divider text-sm font-semibold">IPv6</div>

                <div class="form-control">
                  <label class="label"><span class="label-text">Method</span></label>
                  <select name="profile[ipv6_method]" class="select select-bordered w-full">
                    <option value="auto" selected={@form[:ipv6_method].value == "auto"}>
                      Auto (SLAAC)
                    </option>
                    <option value="manual" selected={@form[:ipv6_method].value == "manual"}>
                      Manual (Static)
                    </option>
                    <option value="link-local" selected={@form[:ipv6_method].value == "link-local"}>
                      Link-Local Only
                    </option>
                    <option value="disabled" selected={@form[:ipv6_method].value == "disabled"}>
                      Disabled
                    </option>
                  </select>
                </div>

                <%= if @form[:ipv6_method].value == "manual" do %>
                  <div class="grid grid-cols-2 gap-4">
                    <div class="form-control">
                      <label class="label"><span class="label-text">Address (CIDR) *</span></label>
                      <input
                        type="text"
                        name="profile[ipv6_address]"
                        value={@form[:ipv6_address].value}
                        placeholder="fd00::1/64"
                        class="input input-bordered w-full"
                      />
                    </div>
                    <div class="form-control">
                      <label class="label"><span class="label-text">Gateway</span></label>
                      <input
                        type="text"
                        name="profile[ipv6_gateway]"
                        value={@form[:ipv6_gateway].value}
                        placeholder="fd00::1"
                        class="input input-bordered w-full"
                      />
                    </div>
                  </div>
                <% end %>

                <%= if @form[:ipv6_method].value not in ["disabled", "link-local"] do %>
                  <div class="grid grid-cols-2 gap-4">
                    <div class="form-control">
                      <label class="label">
                        <span class="label-text">DNS Servers</span>
                      </label>
                      <input
                        type="text"
                        name="profile[ipv6_dns]"
                        value={@form[:ipv6_dns].value}
                        placeholder="2001:4860:4860::8888"
                        class="input input-bordered w-full"
                      />
                      <label class="label">
                        <span class="label-text-alt text-on-surface-variant">
                          Comma-separated
                        </span>
                      </label>
                    </div>
                    <div class="form-control">
                      <label class="label">
                        <span class="label-text">DNS Search Domains</span>
                      </label>
                      <input
                        type="text"
                        name="profile[ipv6_dns_search]"
                        value={@form[:ipv6_dns_search].value}
                        placeholder="example.com"
                        class="input input-bordered w-full"
                      />
                      <label class="label">
                        <span class="label-text-alt text-on-surface-variant">
                          Comma-separated
                        </span>
                      </label>
                    </div>
                  </div>
                <% end %>

                <div class="card-actions justify-end pt-4">
                  <button type="button" phx-click="reset" class="btn btn-ghost">
                    Reset
                  </button>
                  <button type="submit" class="btn btn-primary">
                    <.dm_mdi name="file-document-outline" class="h-4 w-4" />
                    Generate TOML
                  </button>
                </div>
              </.form>
            </div>
          </div>

          <!-- Generated Output -->
          <div class="card bg-surface shadow-xl">
            <div class="card-body">
              <div class="flex items-center justify-between">
                <h2 class="card-title">Generated Profile</h2>
                <%= if @generated_toml do %>
                  <button
                    phx-click="copy_toml"
                    id="copy-toml"
                    phx-hook="CopyToClipboard"
                    data-content={@generated_toml}
                    class="btn btn-ghost btn-sm"
                  >
                    <.dm_mdi name="content-copy" class="h-4 w-4" />
                    Copy
                  </button>
                <% end %>
              </div>

              <%= if @generated_toml do %>
                <div class="bg-surface-container rounded-lg p-4 mt-2">
                  <pre class="text-sm font-mono text-on-surface whitespace-pre"><code>{@generated_toml}</code></pre>
                </div>

                <div class="mt-4 text-sm text-on-surface-variant">
                  <p>
                    Save this file to your profile directory:
                  </p>
                  <div class="bg-surface-container rounded-lg p-3 mt-2 font-mono text-xs">
                    <code>
                      /etc/yellowdog/netman/profiles/{@form[:id].value}.toml
                    </code>
                  </div>
                  <p class="mt-2">
                    The profile will be automatically loaded by the ProfileStore file watcher.
                    No restart required.
                  </p>
                </div>
              <% else %>
                <div class="text-center py-16 text-on-surface-variant">
                  <.dm_mdi name="file-document-edit-outline" class="h-16 w-16 mx-auto mb-4" />
                  <p class="text-lg">Fill in the form and click Generate</p>
                  <p class="text-sm mt-2">
                    The generated TOML profile will appear here
                  </p>
                </div>
              <% end %>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("validate", %{"profile" => params}, socket) do
    form = to_form(Map.merge(@default_form, params), as: "profile")
    {:noreply, assign(socket, form: form, validation_errors: [])}
  end

  def handle_event("generate", %{"profile" => params}, socket) do
    params = Map.merge(@default_form, params)

    case validate_and_generate(params) do
      {:ok, toml} ->
        form = to_form(params, as: "profile")
        {:noreply, assign(socket, form: form, generated_toml: toml, validation_errors: [])}

      {:error, errors} ->
        form = to_form(params, as: "profile")
        {:noreply, assign(socket, form: form, generated_toml: nil, validation_errors: errors)}
    end
  end

  def handle_event("reset", _params, socket) do
    {:noreply,
     assign(socket,
       form: to_form(@default_form, as: "profile"),
       generated_toml: nil,
       validation_errors: []
     )}
  end

  def handle_event("toggle_reference", _params, socket) do
    {:noreply, assign(socket, :show_reference, !socket.assigns.show_reference)}
  end

  def handle_event("copy_toml", _params, socket) do
    {:noreply, put_flash(socket, :info, "Copied to clipboard")}
  end

  # --- Validation & Generation ---

  defp validate_and_generate(params) do
    errors = []

    id = String.trim(params["id"] || "")
    errors = if id == "", do: ["Profile ID is required" | errors], else: errors

    errors =
      if id != "" and not Regex.match?(~r/^[a-zA-Z0-9_\-\.]+$/, id),
        do: ["Profile ID may only contain alphanumeric characters, _, -, ." | errors],
        else: errors

    interface = String.trim(params["interface"] || "")

    errors =
      if interface != "" and byte_size(interface) > 15,
        do: ["Interface name must be at most 15 characters" | errors],
        else: errors

    mtu_str = String.trim(params["mtu"] || "")

    {mtu, errors} = parse_optional_int(mtu_str, "MTU", 68, 65535, errors)

    priority_str = String.trim(params["autoconnect_priority"] || "0")

    {priority, errors} = parse_required_int(priority_str, "Priority", -1000, 10_000, 0, errors)

    ipv4_method = params["ipv4_method"] || "auto"

    errors =
      if ipv4_method == "manual" and String.trim(params["ipv4_address"] || "") == "",
        do: ["IPv4 address is required when method is manual" | errors],
        else: errors

    ipv6_method = params["ipv6_method"] || "auto"

    errors =
      if ipv6_method == "manual" and String.trim(params["ipv6_address"] || "") == "",
        do: ["IPv6 address is required when method is manual" | errors],
        else: errors

    if errors != [] do
      {:error, Enum.reverse(errors)}
    else
      toml = build_toml(params, id, interface, mtu, priority, ipv4_method, ipv6_method)
      {:ok, toml}
    end
  end

  defp build_toml(params, id, interface, mtu, priority, ipv4_method, ipv6_method) do
    autoconnect = params["autoconnect"] == "true"

    lines = [
      "[connection]",
      ~s(id = "#{id}"),
      ~s(type = "ethernet")
    ]

    lines = if interface != "", do: lines ++ [~s(interface = "#{interface}")], else: lines
    lines = lines ++ ["autoconnect = #{autoconnect}"]
    lines = if priority != 0, do: lines ++ ["autoconnect_priority = #{priority}"], else: lines

    zone = String.trim(params["zone"] || "default")
    lines = if zone != "default" and zone != "", do: lines ++ [~s(zone = "#{zone}")], else: lines

    # Ethernet
    lines = if mtu, do: lines ++ ["", "[ethernet]", "mtu = #{mtu}"], else: lines

    # IPv4
    lines = lines ++ ["", "[ipv4]", ~s(method = "#{ipv4_method}")]

    lines =
      if ipv4_method == "manual" do
        addr = String.trim(params["ipv4_address"] || "")
        l = lines ++ [~s(address = "#{addr}")]
        gw = String.trim(params["ipv4_gateway"] || "")
        if gw != "", do: l ++ [~s(gateway = "#{gw}")], else: l
      else
        lines
      end

    lines =
      if ipv4_method != "disabled" do
        dns = parse_csv(params["ipv4_dns"])
        dns_search = parse_csv(params["ipv4_dns_search"])
        l = lines
        l = if dns != [], do: l ++ ["dns = #{format_string_array(dns)}"], else: l
        if dns_search != [], do: l ++ ["dns_search = #{format_string_array(dns_search)}"], else: l
      else
        lines
      end

    # IPv6
    lines = lines ++ ["", "[ipv6]", ~s(method = "#{ipv6_method}")]

    lines =
      if ipv6_method == "manual" do
        addr = String.trim(params["ipv6_address"] || "")
        l = lines ++ [~s(address = "#{addr}")]
        gw = String.trim(params["ipv6_gateway"] || "")
        if gw != "", do: l ++ [~s(gateway = "#{gw}")], else: l
      else
        lines
      end

    lines =
      if ipv6_method not in ["disabled", "link-local"] do
        dns = parse_csv(params["ipv6_dns"])
        dns_search = parse_csv(params["ipv6_dns_search"])
        l = lines
        l = if dns != [], do: l ++ ["dns = #{format_string_array(dns)}"], else: l
        if dns_search != [], do: l ++ ["dns_search = #{format_string_array(dns_search)}"], else: l
      else
        lines
      end

    Enum.join(lines, "\n") <> "\n"
  end

  defp parse_csv(nil), do: []
  defp parse_csv(""), do: []

  defp parse_csv(str) do
    str
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp format_string_array(list) do
    items = Enum.map_join(list, ", ", &~s("#{&1}"))
    "[#{items}]"
  end

  defp parse_optional_int("", _label, _min, _max, errors), do: {nil, errors}

  defp parse_optional_int(str, label, min, max, errors) do
    case Integer.parse(str) do
      {val, ""} when val >= min and val <= max -> {val, errors}
      {_, ""} -> {nil, ["#{label} must be between #{min} and #{max}" | errors]}
      _ -> {nil, ["#{label} must be a valid integer" | errors]}
    end
  end

  defp parse_required_int(str, label, min, max, default, errors) do
    case Integer.parse(str) do
      {val, ""} when val >= min and val <= max -> {val, errors}
      {_, ""} -> {default, ["#{label} must be between #{min} and #{max}" | errors]}
      _ -> {default, ["#{label} must be a valid integer" | errors]}
    end
  end
end
