defmodule YellowDog.Console.MdnsLive.MonitorLive do
  @moduledoc "Management-backed mDNS query monitor for one selected Server."

  use YellowDog.Console, :live_view

  alias YellowDog.Console.ManagementResult
  alias YellowDog.Console.MdnsLive.ManagementSupport
  alias YellowDog.Console.ServerManagement
  alias YellowDog.Sync.Digest

  @limits [50, 100, 200, 500]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "mDNS Monitor",
       subscribed_server_id: nil,
       queries: [],
       cache_entries: [],
       cache_revision: nil,
       limit: 50,
       search: "",
       management_error: nil,
       cached_observed_at: nil,
       commands_enabled?: false
     )}
  end

  @impl true
  def handle_params(%{"server_id" => server_id}, _uri, socket) do
    socket = ManagementSupport.subscribe(socket, server_id)
    {:noreply, if(connected?(socket), do: load_monitor(socket), else: socket)}
  end

  @impl true
  def handle_event("refresh", _params, socket), do: {:noreply, load_monitor(socket)}

  def handle_event("search", %{"search" => search}, socket),
    do: {:noreply, assign(socket, :search, search)}

  def handle_event("set_limit", %{"limit" => limit}, socket) do
    case Integer.parse(limit) do
      {limit, ""} when limit in @limits ->
        {:noreply, socket |> assign(:limit, limit) |> load_monitor()}

      _invalid ->
        {:noreply, socket}
    end
  end

  def handle_event("clear_cache", _params, socket) do
    with true <- socket.assigns.commands_enabled?,
         revision when is_binary(revision) <- socket.assigns.cache_revision do
      result =
        ServerManagement.mdns_cache_clear(
          socket.assigns.selected_server.id,
          %{},
          expected_revision: revision,
          idempotency_key: Ecto.UUID.generate()
        )

      case result do
        %ManagementResult{status: :ok, value: %{"cleared_entries" => _count}} ->
          {:noreply,
           socket
           |> assign(cache_entries: [], cache_revision: cache_revision([]))
           |> put_flash(:info, "Cache cleared")}

        %ManagementResult{status: :error, message: message} ->
          {:noreply, put_flash(socket, :error, message)}
      end
    else
      false -> {:noreply, put_flash(socket, :error, "The selected Server is offline")}
      nil -> {:noreply, put_flash(socket, :error, "Cache revision is unavailable")}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:server_connection, _state, %{server_id: server_id}}, socket)
      when server_id == socket.assigns.selected_server.id do
    {:noreply,
     socket
     |> ManagementSupport.refresh_selected_server(server_id)
     |> load_monitor()}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp load_monitor(socket) do
    server_id = socket.assigns.selected_server.id

    query_result =
      ServerManagement.mdns_monitor_list(server_id, %{"limit" => socket.assigns.limit})

    cache_result = ServerManagement.mdns_cache_get(server_id)
    queries = result_items(query_result)
    cache_entries = cache_entries(cache_result)
    results = [query_result, cache_result]

    assign(socket,
      page_title: "#{socket.assigns.selected_server.name || server_id} — mDNS Monitor",
      queries: queries,
      cache_entries: cache_entries,
      cache_revision: if(success?(cache_result), do: cache_revision(cache_entries), else: nil),
      management_error: first_error(results),
      cached_observed_at: latest_observed_at(results),
      commands_enabled?: socket.assigns.service_online? and success?(cache_result)
    )
  end

  defp result_items(%ManagementResult{status: :ok, value: %{"items" => items}})
       when is_list(items),
       do: items

  defp result_items(_result), do: []

  defp cache_entries(%ManagementResult{status: :ok, value: %{"entries" => entries}})
       when is_list(entries),
       do: entries

  defp cache_entries(_result), do: []

  defp cache_revision(entries) do
    case Digest.calculate(%{"entries" => entries}) do
      {:ok, revision} -> revision
      {:error, _error} -> nil
    end
  end

  defp success?(%ManagementResult{status: :ok}), do: true
  defp success?(_result), do: false

  defp first_error(results) do
    Enum.find_value(results, fn
      %ManagementResult{status: :error} = result -> result
      _result -> nil
    end)
  end

  defp latest_observed_at(results) do
    results
    |> Enum.flat_map(fn
      %ManagementResult{observed_at: %DateTime{} = observed_at} -> [observed_at]
      _result -> []
    end)
    |> Enum.max_by(&DateTime.to_unix(&1, :microsecond), fn -> nil end)
  end

  defp filtered_queries(queries, search) do
    term = String.downcase(search)

    if term == "" do
      queries
    else
      Enum.filter(queries, fn query ->
        Enum.any?(["query_name", "record_type", "source_address"], fn key ->
          String.contains?(String.downcase(to_string(query[key] || "")), term)
        end)
      end)
    end
  end
end
