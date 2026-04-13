defmodule YellowDog.Console.DnsLive.ProviderLive.Show do
  @moduledoc """
  DNS Provider detail page showing configuration, sync status,
  zone list, and management controls.
  """
  use YellowDog.Console, :live_view

  import YellowDog.Console.ServiceHelper, only: [safe_call: 3]

  alias YellowDog.Console.DnsLive.ProviderLive.Index, as: ProviderIndex

  @sensitive_keys ~w(secret token key password api_key api_token access_key)

  @impl true
  def mount(%{"name" => name}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, "dns_provider:sync")
      Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, "dns_provider:config")
    end

    {:ok,
     socket
     |> assign(:provider_name, name)
     |> assign_provider_data()}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action)}
  end

  defp apply_action(socket, :edit) do
    assign(socket, :page_title, "Edit #{socket.assigns.provider_name}")
  end

  defp apply_action(socket, _action) do
    assign(socket, :page_title, "Provider: #{socket.assigns.provider_name}")
  end

  # ------------------------------------------------------------------
  # Events
  # ------------------------------------------------------------------

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, assign_provider_data(socket)}
  end

  def handle_event("sync_now", _params, socket) do
    name = socket.assigns.provider_name

    safe_call(YellowDog.DnsProvider, fn -> YellowDog.DnsProvider.sync_now(name) end, :ok)

    {:noreply,
     socket
     |> put_flash(:info, "Sync triggered for #{name}")
     |> assign_provider_data()}
  end

  def handle_event("sync_zone", %{"zone" => zone}, socket) do
    name = socket.assigns.provider_name

    safe_call(
      YellowDog.DnsProvider,
      fn -> YellowDog.DnsProvider.sync_now(name, zone) end,
      :ok
    )

    {:noreply,
     socket
     |> put_flash(:info, "Sync triggered for zone #{zone}")
     |> assign_provider_data()}
  end

  def handle_event("toggle_enabled", _params, socket) do
    name = socket.assigns.provider_name
    config = socket.assigns.config

    if config[:enabled] do
      safe_call(YellowDog.DnsProvider, fn -> YellowDog.DnsProvider.stop_provider(name) end, :ok)
    else
      safe_call(YellowDog.DnsProvider, fn -> YellowDog.DnsProvider.start_provider(name) end, :ok)
    end

    {:noreply,
     socket
     |> put_flash(:info, "Provider #{name} #{if config[:enabled], do: "disabled", else: "enabled"}")
     |> assign_provider_data()}
  end

  # ------------------------------------------------------------------
  # PubSub
  # ------------------------------------------------------------------

  @impl true
  def handle_info({:dns_provider, _event}, socket) do
    {:noreply, assign_provider_data(socket)}
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # ------------------------------------------------------------------
  # Data loading
  # ------------------------------------------------------------------

  defp assign_provider_data(socket) do
    name = socket.assigns.provider_name

    providers =
      safe_call(YellowDog.DnsProvider, fn -> YellowDog.DnsProvider.list_providers() end, [])

    provider = Enum.find(providers, fn p -> p.name == name end)

    config =
      if provider do
        %{
          type: provider.type,
          enabled: provider.enabled,
          status: provider.status
        }
      else
        %{type: nil, enabled: false, status: :stopped}
      end

    sync_status =
      case safe_call(YellowDog.DnsProvider, fn -> YellowDog.DnsProvider.sync_status(name) end, {:error, :not_found}) do
        {:ok, status} -> status
        _ -> %{}
      end

    conflicts =
      safe_call(YellowDog.DnsProvider, fn -> YellowDog.DnsProvider.list_conflicts(name) end, [])

    socket
    |> assign(:config, config)
    |> assign(:sync_status, sync_status)
    |> assign(:zones, Map.get(sync_status, :zones, []))
    |> assign(:conflict_count, length(conflicts))
  end

  # ------------------------------------------------------------------
  # Template helpers
  # ------------------------------------------------------------------

  @doc false
  def mask_credentials(nil), do: %{}

  def mask_credentials(creds) when is_map(creds) do
    Map.new(creds, fn {key, value} ->
      if sensitive_key?(key) do
        {key, mask_value(value)}
      else
        {key, value}
      end
    end)
  end

  def mask_credentials(_), do: %{}

  defp sensitive_key?(key) when is_binary(key) do
    lower = String.downcase(key)
    Enum.any?(@sensitive_keys, &String.contains?(lower, &1))
  end

  defp sensitive_key?(_), do: false

  defp mask_value(value) when is_binary(value) and byte_size(value) > 4 do
    String.slice(value, 0, 4) <> String.duplicate("*", 8)
  end

  defp mask_value(_), do: "****"

  defdelegate format_sync_time(time), to: ProviderIndex
  defdelegate format_type(type), to: ProviderIndex
end
