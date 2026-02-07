defmodule YellowDog.Console.DiagnosticsLive do
  @moduledoc """
  Service Diagnostics LiveView for testing DNS, mDNS, DHCPv4, and DHCPv6 services.

  Provides forms for sending protocol-specific queries, displays request/response
  in struct and raw hex views, and maintains query history per tab.
  """
  use YellowDog.Console, :live_view

  alias YellowDog.Console.DiagnosticsLive.DnsTab
  alias YellowDog.Console.DiagnosticsLive.MdnsTab
  alias YellowDog.Console.DiagnosticsLive.Dhcpv4Tab
  alias YellowDog.Console.DiagnosticsLive.Dhcpv6Tab
  alias YellowDog.Console.Diagnostics.DnsClient
  alias YellowDog.Console.Diagnostics.MdnsClient
  alias YellowDog.Console.Diagnostics.Dhcpv4Client
  alias YellowDog.Console.Diagnostics.Dhcpv6Client

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Service Diagnostics")
     |> assign(:active_tab, :dns)
     |> assign(:display_mode, :struct)
     |> assign(:history_visible, false)
     |> assign(:tabs, init_tabs())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div class="max-w-7xl">
        <h1 class="text-2xl font-bold mb-4">Service Diagnostics</h1>

        <%!-- Tab Navigation --%>
        <div role="tablist" class="tabs tabs-boxed mb-4">
          <button
            role="tab"
            class={["tab", @active_tab == :dns && "tab-active"]}
            phx-click="select_tab"
            phx-value-tab="dns"
          >
            DNS
          </button>
          <button
            role="tab"
            class={["tab", @active_tab == :mdns && "tab-active"]}
            phx-click="select_tab"
            phx-value-tab="mdns"
          >
            mDNS
          </button>
          <button
            role="tab"
            class={["tab", @active_tab == :dhcpv4 && "tab-active"]}
            phx-click="select_tab"
            phx-value-tab="dhcpv4"
          >
            DHCPv4
          </button>
          <button
            role="tab"
            class={["tab", @active_tab == :dhcpv6 && "tab-active"]}
            phx-click="select_tab"
            phx-value-tab="dhcpv6"
          >
            DHCPv6
          </button>
        </div>

        <%!-- Display Mode Toggle --%>
        <div class="flex justify-end mb-4">
          <div class="join">
            <button
              class={["btn btn-sm join-item", @display_mode == :struct && "btn-active"]}
              phx-click="toggle_display_mode"
              phx-value-mode="struct"
            >
              Struct
            </button>
            <button
              class={["btn btn-sm join-item", @display_mode == :raw && "btn-active"]}
              phx-click="toggle_display_mode"
              phx-value-mode="raw"
            >
              Raw Hex
            </button>
          </div>
        </div>

        <%!-- Tab Content --%>
        <div>
          <%= case @active_tab do %>
            <% :dns -> %>
              <DnsTab.render
                tab={@tabs.dns}
                display_mode={@display_mode}
                history_visible={@history_visible}
              />
            <% :mdns -> %>
              <MdnsTab.render
                tab={@tabs.mdns}
                display_mode={@display_mode}
                history_visible={@history_visible}
              />
            <% :dhcpv4 -> %>
              <Dhcpv4Tab.render
                tab={@tabs.dhcpv4}
                display_mode={@display_mode}
                history_visible={@history_visible}
              />
            <% :dhcpv6 -> %>
              <Dhcpv6Tab.render
                tab={@tabs.dhcpv6}
                display_mode={@display_mode}
                history_visible={@history_visible}
              />
          <% end %>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # Event Handlers

  @valid_tabs ~w(dns mdns dhcpv4 dhcpv6)
  @valid_display_modes ~w(struct raw)

  @impl true
  def handle_event("select_tab", %{"tab" => tab}, socket) when tab in @valid_tabs do
    {:noreply, assign(socket, :active_tab, String.to_existing_atom(tab))}
  end

  @impl true
  def handle_event("select_tab", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_display_mode", %{"mode" => mode}, socket)
      when mode in @valid_display_modes do
    {:noreply, assign(socket, :display_mode, String.to_existing_atom(mode))}
  end

  @impl true
  def handle_event("toggle_display_mode", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_history", _params, socket) do
    {:noreply, update(socket, :history_visible, &(!&1))}
  end

  @impl true
  def handle_event("clear_history", _params, socket) do
    active_tab = socket.assigns.active_tab
    {:noreply, update_tab(socket, active_tab, &Map.put(&1, :history, []))}
  end

  @impl true
  def handle_event("select_history", %{"id" => id}, socket) do
    active_tab = socket.assigns.active_tab
    tab_state = socket.assigns.tabs[active_tab]

    case Enum.find(tab_state.history, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      result ->
        socket =
          update_tab(socket, active_tab, fn tab ->
            %{tab | form: result.params, current_result: result}
          end)

        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("copied", _params, socket) do
    {:noreply, put_flash(socket, :info, "Copied to clipboard")}
  end

  @impl true
  def handle_event("copy_failed", %{"error" => error}, socket) do
    {:noreply, put_flash(socket, :error, "Copy failed: #{error}")}
  end

  # DNS Events
  @impl true
  def handle_event("validate_dns", %{"dns_query" => params}, socket) do
    {:noreply, update_tab(socket, :dns, &Map.put(&1, :form, atomize_keys(params)))}
  end

  @impl true
  def handle_event("send_dns_query", %{"dns_query" => params}, socket) do
    params = atomize_keys(params)

    socket =
      socket
      |> update_tab(:dns, &Map.merge(&1, %{loading: true, form: params}))
      |> start_async(:dns_query, fn -> DnsClient.query(params) end)

    {:noreply, socket}
  end

  # mDNS Events
  @impl true
  def handle_event("validate_mdns", %{"mdns_query" => params}, socket) do
    {:noreply, update_tab(socket, :mdns, &Map.put(&1, :form, atomize_keys(params)))}
  end

  @impl true
  def handle_event("send_mdns_query", %{"mdns_query" => params}, socket) do
    params = atomize_keys(params)

    socket =
      socket
      |> update_tab(:mdns, &Map.merge(&1, %{loading: true, form: params}))
      |> start_async(:mdns_query, fn -> MdnsClient.query(params) end)

    {:noreply, socket}
  end

  # DHCPv4 Events
  @impl true
  def handle_event("validate_dhcpv4", %{"dhcpv4_query" => params}, socket) do
    {:noreply, update_tab(socket, :dhcpv4, &Map.put(&1, :form, atomize_keys(params)))}
  end

  @impl true
  def handle_event("send_dhcpv4_query", %{"dhcpv4_query" => params}, socket) do
    params = atomize_keys(params)

    socket =
      socket
      |> update_tab(:dhcpv4, &Map.merge(&1, %{loading: true, form: params}))
      |> start_async(:dhcpv4_query, fn -> Dhcpv4Client.query(params) end)

    {:noreply, socket}
  end

  # DHCPv6 Events
  @impl true
  def handle_event("validate_dhcpv6", %{"dhcpv6_query" => params}, socket) do
    {:noreply, update_tab(socket, :dhcpv6, &Map.put(&1, :form, atomize_keys(params)))}
  end

  @impl true
  def handle_event("send_dhcpv6_query", %{"dhcpv6_query" => params}, socket) do
    params = atomize_keys(params)

    socket =
      socket
      |> update_tab(:dhcpv6, &Map.merge(&1, %{loading: true, form: params}))
      |> start_async(:dhcpv6_query, fn -> Dhcpv6Client.query(params) end)

    {:noreply, socket}
  end

  # Async Handlers
  @impl true
  def handle_async(:dns_query, {:ok, result}, socket) do
    socket = handle_query_result(socket, :dns, result)
    {:noreply, socket}
  end

  @impl true
  def handle_async(:dns_query, {:exit, reason}, socket) do
    socket = handle_query_error(socket, :dns, reason)
    {:noreply, socket}
  end

  @impl true
  def handle_async(:mdns_query, {:ok, result}, socket) do
    socket = handle_query_result(socket, :mdns, result)
    {:noreply, socket}
  end

  @impl true
  def handle_async(:mdns_query, {:exit, reason}, socket) do
    socket = handle_query_error(socket, :mdns, reason)
    {:noreply, socket}
  end

  @impl true
  def handle_async(:dhcpv4_query, {:ok, result}, socket) do
    socket = handle_query_result(socket, :dhcpv4, result)
    {:noreply, socket}
  end

  @impl true
  def handle_async(:dhcpv4_query, {:exit, reason}, socket) do
    socket = handle_query_error(socket, :dhcpv4, reason)
    {:noreply, socket}
  end

  @impl true
  def handle_async(:dhcpv6_query, {:ok, result}, socket) do
    socket = handle_query_result(socket, :dhcpv6, result)
    {:noreply, socket}
  end

  @impl true
  def handle_async(:dhcpv6_query, {:exit, reason}, socket) do
    socket = handle_query_error(socket, :dhcpv6, reason)
    {:noreply, socket}
  end

  # Private Functions

  defp init_tabs do
    %{
      dns: %{
        form: default_dns_form(),
        loading: false,
        current_result: nil,
        history: []
      },
      mdns: %{
        form: default_mdns_form(),
        loading: false,
        current_result: nil,
        history: []
      },
      dhcpv4: %{
        form: default_dhcpv4_form(),
        loading: false,
        current_result: nil,
        history: []
      },
      dhcpv6: %{
        form: default_dhcpv6_form(),
        loading: false,
        current_result: nil,
        history: []
      }
    }
  end

  defp default_dns_form do
    %{
      query_name: "",
      record_type: "a",
      server: "127.0.0.1",
      port: "53",
      protocol: "udp",
      recursion_desired: "true",
      timeout: "5000"
    }
  end

  defp default_mdns_form do
    %{
      service_type: "_http._tcp.local",
      query_type: "ptr",
      timeout: "3000"
    }
  end

  defp default_dhcpv4_form do
    %{
      message_type: "discover",
      client_mac: "",
      transaction_id: "",
      requested_options: "1,3,6,15",
      timeout: "10000"
    }
  end

  defp default_dhcpv6_form do
    %{
      message_type: "solicit",
      duid: "",
      transaction_id: "",
      iaid: "",
      requested_options: "23",
      timeout: "10000"
    }
  end

  defp update_tab(socket, tab_key, update_fn) do
    update(socket, :tabs, fn tabs ->
      Map.update!(tabs, tab_key, update_fn)
    end)
  end

  defp handle_query_result(socket, tab_key, {:ok, result}) do
    socket
    |> update_tab(tab_key, fn tab ->
      %{
        tab
        | loading: false,
          current_result: result,
          history: add_to_history(tab.history, result)
      }
    end)
  end

  defp handle_query_result(socket, tab_key, {:error, reason}) do
    error_message = format_error(reason)

    socket
    |> update_tab(tab_key, &Map.put(&1, :loading, false))
    |> put_flash(:error, "Query failed: #{error_message}")
  end

  defp handle_query_error(socket, tab_key, reason) do
    error_message = format_error(reason)

    socket
    |> update_tab(tab_key, &Map.put(&1, :loading, false))
    |> put_flash(:error, "Query failed: #{error_message}")
  end

  defp add_to_history(history, result) do
    [result | history]
    |> Enum.take(10)
  end

  defp format_error(:timeout), do: "Query timed out"

  defp format_error({:socket_error, :eacces}),
    do: "Permission denied (privileged port requires root)"

  defp format_error({:socket_error, reason}), do: "Socket error: #{inspect(reason)}"
  defp format_error({:parse_error, reason}), do: "Parse error: #{reason}"
  defp format_error(reason), do: inspect(reason)

  @valid_form_keys ~w(query_name record_type server port protocol recursion_desired timeout
    service_type query_type message_type client_mac transaction_id requested_options
    duid iaid)

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {atomize_key(k), v} end)
  end

  defp atomize_key(key) when is_binary(key) and key in @valid_form_keys do
    String.to_existing_atom(key)
  end

  defp atomize_key(key) when is_binary(key), do: key
  defp atomize_key(key) when is_atom(key), do: key
end
