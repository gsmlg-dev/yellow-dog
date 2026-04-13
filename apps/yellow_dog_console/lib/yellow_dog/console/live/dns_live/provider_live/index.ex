defmodule YellowDog.Console.DnsLive.ProviderLive.Index do
  @moduledoc """
  DNS Provider list page showing all configured providers with status,
  sync controls, and management actions.
  """
  use YellowDog.Console, :live_view

  import YellowDog.Console.ServiceHelper, only: [safe_call: 3]

  @valid_types ~w(iana_root aws cloudflare gcp vultr)
  @valid_strategies ~w(local_wins remote_wins manual)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, "dns_provider:sync")
      Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, "dns_provider:config")
    end

    {:ok,
     assign(socket,
       page_title: "DNS Providers",
       providers: list_providers(),
       delete_confirm: nil,
       show_form: false,
       form: new_form()
     )}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action)}
  end

  defp apply_action(socket, :new) do
    socket
    |> assign(:page_title, "Add DNS Provider")
    |> assign(:show_form, true)
    |> assign(:form, new_form())
  end

  defp apply_action(socket, _action) do
    socket
    |> assign(:page_title, "DNS Providers")
    |> assign(:show_form, false)
  end

  # ------------------------------------------------------------------
  # Events
  # ------------------------------------------------------------------

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, assign(socket, :providers, list_providers())}
  end

  def handle_event("sync_now", %{"name" => name}, socket) do
    safe_call(YellowDog.DnsProvider, fn -> YellowDog.DnsProvider.sync_now(name) end, :ok)

    {:noreply,
     socket
     |> put_flash(:info, "Sync triggered for #{name}")
     |> assign(:providers, list_providers())}
  end

  def handle_event("confirm_delete", %{"name" => name}, socket) do
    {:noreply, assign(socket, :delete_confirm, name)}
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, :delete_confirm, nil)}
  end

  def handle_event("delete", %{"name" => name}, socket) do
    safe_call(YellowDog.DnsProvider, fn -> YellowDog.DnsProvider.remove_provider(name) end, :ok)

    {:noreply,
     socket
     |> put_flash(:info, "Provider #{name} deleted")
     |> assign(:delete_confirm, nil)
     |> assign(:providers, list_providers())}
  end

  def handle_event("toggle_enabled", %{"name" => name, "enabled" => "true"}, socket) do
    safe_call(YellowDog.DnsProvider, fn -> YellowDog.DnsProvider.stop_provider(name) end, :ok)

    {:noreply,
     socket
     |> put_flash(:info, "Provider #{name} disabled")
     |> assign(:providers, list_providers())}
  end

  def handle_event("toggle_enabled", %{"name" => name, "enabled" => "false"}, socket) do
    safe_call(YellowDog.DnsProvider, fn -> YellowDog.DnsProvider.start_provider(name) end, :ok)

    {:noreply,
     socket
     |> put_flash(:info, "Provider #{name} enabled")
     |> assign(:providers, list_providers())}
  end

  def handle_event("validate_form", %{"provider" => params}, socket) do
    {:noreply, assign(socket, :form, to_form(params, as: "provider"))}
  end

  def handle_event("save_provider", %{"provider" => params}, socket) do
    type = normalize_type(params["type"])
    strategy = normalize_strategy(params["conflict_strategy"])

    zones =
      (params["zones"] || "")
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)

    attrs = %{
      name: params["name"],
      type: type,
      zones: zones,
      sync_interval: String.to_integer(params["sync_interval"] || "300"),
      conflict_strategy: strategy,
      enabled: true,
      credentials: parse_credentials(params["credentials"] || "")
    }

    case safe_call(YellowDog.DnsProvider, fn -> YellowDog.DnsProvider.add_provider(attrs) end, {:error, :service_unavailable}) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "Provider #{attrs.name} created")
         |> push_navigate(to: ~p"/server/dns/providers")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to create provider: #{inspect(reason)}")}
    end
  end

  # ------------------------------------------------------------------
  # PubSub
  # ------------------------------------------------------------------

  @impl true
  def handle_info({:dns_provider, _event}, socket) do
    {:noreply, assign(socket, :providers, list_providers())}
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  defp list_providers do
    providers =
      safe_call(YellowDog.DnsProvider, fn -> YellowDog.DnsProvider.list_providers() end, [])

    Enum.map(providers, fn p ->
      status_info =
        safe_call(YellowDog.DnsProvider, fn -> YellowDog.DnsProvider.sync_status(p.name) end, {:error, :not_found})

      sync_status =
        case status_info do
          {:ok, info} -> info
          _ -> %{}
        end

      Map.merge(p, %{
        last_sync: Map.get(sync_status, :last_sync),
        sync_count: Map.get(sync_status, :sync_count, 0),
        last_error: Map.get(sync_status, :last_error)
      })
    end)
  end

  defp new_form do
    to_form(
      %{
        "name" => "",
        "type" => "cloudflare",
        "zones" => "",
        "sync_interval" => "300",
        "conflict_strategy" => "local_wins",
        "credentials" => ""
      },
      as: "provider"
    )
  end

  defp normalize_type(type) when type in @valid_types, do: String.to_existing_atom(type)
  defp normalize_type(_), do: :cloudflare

  defp normalize_strategy(s) when s in @valid_strategies, do: String.to_existing_atom(s)
  defp normalize_strategy(_), do: :local_wins

  defp parse_credentials(""), do: nil

  defp parse_credentials(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, "=", parts: 2) do
        [key, value] -> Map.put(acc, String.trim(key), String.trim(value))
        _ -> acc
      end
    end)
  end

  @doc false
  def format_sync_time(nil), do: "Never"

  def format_sync_time(unix) when is_integer(unix) do
    case DateTime.from_unix(unix) do
      {:ok, dt} -> Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
      _ -> "Unknown"
    end
  end

  def format_sync_time(_), do: "Unknown"

  @doc false
  def format_type(type) when is_atom(type) do
    type
    |> to_string()
    |> String.replace("_", " ")
    |> String.split(" ")
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  def format_type(type), do: to_string(type)
end
