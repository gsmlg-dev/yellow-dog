defmodule YellowDog.Console.Dhcpv6Live.PoolsLive do
  @moduledoc "Management-backed DHCPv6 address pools for one selected Server."

  use YellowDog.Console, :live_view

  alias YellowDog.Console.DhcpLive.ManagementComponents
  alias YellowDog.Console.DhcpLive.ManagementSupport
  alias YellowDog.Console.ManagementResult
  alias YellowDog.Console.ServerManagement
  alias YellowDog.Console.ServicePaths
  alias YellowDog.Console.Settings.AddressPool

  @family :ipv6
  @service_type :dhcpv6

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "DHCPv6 Address Pools",
       subscribed_server_id: nil,
       family: @family,
       family_label: ManagementSupport.family_label(@family),
       service_type: @service_type,
       base_path: nil,
       all_pools: [],
       pools: [],
       filter: "",
       show_form: false,
       form_mode: :create,
       editing_pool: nil,
       commands_enabled?: false,
       management_error: nil,
       cached_observed_at: nil
     )}
  end

  @impl true
  def handle_params(%{"server_id" => server_id}, _uri, socket) do
    socket =
      socket
      |> ManagementSupport.subscribe(server_id)
      |> assign(:base_path, ServicePaths.server_path(server_id, :dhcpv6))

    {:noreply, if(connected?(socket), do: load_pools(socket), else: socket)}
  end

  @impl true
  def handle_event("show_new_form", _params, socket) do
    case ManagementSupport.mutable(socket) do
      :ok ->
        {:noreply,
         assign(socket,
           show_form: true,
           form_mode: :create,
           editing_pool: nil
         )}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("show_edit_form", %{"pool-name" => pool_id}, socket) do
    with :ok <- ManagementSupport.mutable(socket),
         pool when not is_nil(pool) <-
           ManagementSupport.find_pool(socket.assigns.all_pools, pool_id) do
      {:noreply,
       assign(socket,
         show_form: true,
         form_mode: :edit,
         editing_pool: address_pool(pool)
       )}
    else
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
      nil -> {:noreply, put_flash(socket, :error, "Pool revision is unavailable")}
    end
  end

  def handle_event("delete_pool", %{"pool-name" => pool_id}, socket),
    do: delete_pool(socket, pool_id, false)

  def handle_event("force_delete_pool", %{"pool-name" => pool_id}, socket),
    do: delete_pool(socket, pool_id, true)

  def handle_event("filter", %{"filter" => filter}, socket) do
    {:noreply, socket |> assign(:filter, filter) |> filter_pools()}
  end

  def handle_event("refresh", _params, socket), do: {:noreply, load_pools(socket)}
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info(:close_pool_form, socket) do
    {:noreply, assign(socket, show_form: false, editing_pool: nil)}
  end

  def handle_info(
        {:pool_saved, @service_type, %AddressPool{protocol: @family} = pool, mode},
        socket
      )
      when mode in [:create, :edit] do
    save_pool(socket, pool, mode)
  end

  def handle_info({:server_connection, _state, %{server_id: server_id}}, socket)
      when server_id == socket.assigns.selected_server.id do
    {:noreply,
     socket
     |> ManagementSupport.refresh_selected_server(server_id)
     |> load_pools()}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns), do: ManagementComponents.pools(assigns)

  defp load_pools(socket) do
    server_id = socket.assigns.selected_server.id
    payload = %{"family" => ManagementSupport.family_wire(@family)}
    status = ServerManagement.dhcp_status_get(server_id, payload)
    pools_result = ServerManagement.dhcp_pools_list(server_id, payload)
    results = [status, pools_result]
    management_error = ManagementSupport.first_error(results)

    socket
    |> assign(
      page_title: "#{socket.assigns.selected_server.name || server_id} — DHCPv6 Pools",
      all_pools:
        pools_result
        |> ManagementSupport.items(@family)
        |> ManagementSupport.pool_views(),
      commands_enabled?:
        socket.assigns.service_online? and is_nil(management_error) and
          not ManagementSupport.cached?(results),
      management_error: management_error,
      cached_observed_at:
        ManagementSupport.cached_observed_at(results, socket.assigns.selected_server.last_seen_at)
    )
    |> filter_pools()
  end

  defp filter_pools(socket) do
    assign(
      socket,
      :pools,
      ManagementSupport.filter_pools(socket.assigns.all_pools, socket.assigns.filter)
    )
  end

  defp delete_pool(socket, pool_id, force?) do
    with :ok <- ManagementSupport.mutable(socket),
         pool when not is_nil(pool) <-
           ManagementSupport.find_pool(socket.assigns.all_pools, pool_id),
         opts when is_list(opts) <- ManagementSupport.command_options(pool.resource) do
      payload = %{"family" => ManagementSupport.family_wire(@family), "pool_id" => pool_id}

      result =
        if force? do
          ServerManagement.dhcp_pools_force_delete(
            socket.assigns.selected_server.id,
            Map.put(payload, "force", true),
            opts
          )
        else
          ServerManagement.dhcp_pools_delete(socket.assigns.selected_server.id, payload, opts)
        end

      finish_delete(socket, result, pool_id, force?)
    else
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
      nil -> {:noreply, put_flash(socket, :error, "Pool revision is unavailable")}
      _invalid -> {:noreply, put_flash(socket, :error, "Pool revision is unavailable")}
    end
  end

  defp finish_delete(socket, %ManagementResult{status: :ok}, pool_id, force?) do
    message = if force?, do: "Pool force deleted successfully", else: "Pool deleted successfully"

    {:noreply,
     socket
     |> assign(:all_pools, ManagementSupport.delete_pool(socket.assigns.all_pools, pool_id))
     |> filter_pools()
     |> put_flash(:info, message)}
  end

  defp finish_delete(
         socket,
         %ManagementResult{status: :error, message: message},
         _pool_id,
         _force?
       ),
       do: {:noreply, put_flash(socket, :error, message)}

  defp save_pool(socket, pool, mode) do
    with :ok <- ManagementSupport.mutable(socket),
         :ok <- supported_fields(pool),
         :ok <- supported_lifetime(pool),
         {:ok, opts} <- save_options(socket.assigns.all_pools, pool, mode) do
      result =
        case mode do
          :create ->
            ServerManagement.dhcp_pools_create(
              socket.assigns.selected_server.id,
              pool_payload(pool),
              opts
            )

          :edit ->
            ServerManagement.dhcp_pools_update(
              socket.assigns.selected_server.id,
              pool_payload(pool),
              opts
            )
        end

      finish_save(socket, result, mode)
    else
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  defp save_options(_pools, _pool, :create),
    do: {:ok, ManagementSupport.create_options()}

  defp save_options(pools, pool, :edit) do
    with current when not is_nil(current) <- ManagementSupport.find_pool(pools, pool.id),
         opts when is_list(opts) <- ManagementSupport.command_options(current.resource) do
      {:ok, opts}
    else
      _missing -> {:error, "Pool revision is unavailable"}
    end
  end

  defp finish_save(
         socket,
         %ManagementResult{status: :ok, value: %{"resource" => resource}},
         mode
       ) do
    message =
      if mode == :create, do: "Pool created successfully", else: "Pool updated successfully"

    {:noreply,
     socket
     |> assign(
       all_pools: ManagementSupport.put_pool(socket.assigns.all_pools, resource),
       show_form: false,
       editing_pool: nil
     )
     |> filter_pools()
     |> put_flash(:info, message)}
  end

  defp finish_save(socket, %ManagementResult{status: :error, message: message}, _mode),
    do: {:noreply, put_flash(socket, :error, message)}

  defp pool_payload(pool) do
    %{
      "family" => ManagementSupport.family_wire(@family),
      "pool_id" => pool.name,
      "subnet" => pool.network,
      "start_address" => pool.range_start,
      "end_address" => pool.range_end,
      "lease_seconds" => pool.valid_lifetime
    }
  end

  defp supported_lifetime(%AddressPool{
         preferred_lifetime: lease_seconds,
         valid_lifetime: lease_seconds
       })
       when is_integer(lease_seconds),
       do: :ok

  defp supported_lifetime(_pool),
    do: {:error, "Preferred and valid lifetimes must match for Server management"}

  defp supported_fields(%AddressPool{gateway: gateway, dns_servers: dns_servers})
       when gateway in [nil, ""] and dns_servers in [nil, []],
       do: :ok

  defp supported_fields(_pool),
    do: {:error, "Gateway and DNS values are unavailable for Server-managed pool resources"}

  defp address_pool(pool) do
    %AddressPool{
      id: pool.name,
      name: pool.name,
      protocol: @family,
      network: pool.network,
      range_start: pool.range_start,
      range_end: pool.range_end,
      preferred_lifetime: pool.lease_time,
      valid_lifetime: pool.lease_time,
      dns_servers: pool.dns_servers
    }
  end
end
