defmodule YellowDog.Store.DynDnsUpdater do
  @moduledoc """
  GenServer that subscribes to DHCP lease events and creates/updates
  dynamic DNS records.

  Responsibilities:
  - Lease bound → Create forward (A/AAAA) + reverse (PTR) DNS records
  - Lease renewed → Update DNS record TTL
  - Lease released → Delete DNS records immediately
  - Lease expired → No action (DNS records auto-expire via TTL)

  Lives in the `yellow_dog` core app supervision tree since it bridges
  DHCP and DNS domains.
  """

  use GenServer
  require Logger

  alias YellowDog.Store.{DynDns, EventBridge}

  @lease_event_pattern "dhcp:lease:*"

  # ── Public API ──────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # ── GenServer Callbacks ─────────────────────────────────────────

  @resubscribe_delay_ms 1_000

  @impl true
  def init(opts) do
    domain = Keyword.get(opts, :domain, "local")
    state = %{domain: domain, subscription_ref: nil, bridge_monitor: nil}

    {:ok, subscribe_to_bridge(state)}
  end

  @impl true
  def handle_info({:store_event, event}, state) do
    handle_lease_event(event, state)
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    # EventBridge crashed — re-subscribe after delay
    Process.send_after(self(), :resubscribe, @resubscribe_delay_ms)
    {:noreply, %{state | subscription_ref: nil, bridge_monitor: nil}}
  end

  def handle_info(:resubscribe, state) do
    {:noreply, subscribe_to_bridge(state)}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{subscription_ref: ref}) when not is_nil(ref) do
    try do
      EventBridge.unsubscribe(ref)
    rescue
      _ -> :ok
    end
  end

  def terminate(_reason, _state), do: :ok

  # ── Event Handlers ──────────────────────────────────────────────

  defp handle_lease_event(%{type: :put, key: key, value: lease}, state) do
    case lease do
      %{state: :bound, hostname: hostname, ip: ip} when is_binary(hostname) and hostname != "" ->
        handle_bind(hostname, ip, lease, key, state)

      %{state: :renewing, hostname: hostname, ip: ip}
      when is_binary(hostname) and hostname != "" ->
        handle_renew(hostname, ip, lease, state)

      %{state: :released, hostname: hostname} when is_binary(hostname) and hostname != "" ->
        handle_release(hostname, state)

      _ ->
        :ok
    end
  end

  defp handle_lease_event(%{type: :delete, value: lease}, state) when is_map(lease) do
    case lease do
      %{hostname: hostname} when is_binary(hostname) and hostname != "" ->
        handle_release(hostname, state)

      _ ->
        :ok
    end
  end

  defp handle_lease_event(_event, _state), do: :ok

  defp handle_bind(hostname, ip, lease, source_key, state) do
    fqdn = build_fqdn(hostname, state.domain)
    ttl = Map.get(lease, :lease_duration, 3600)

    # Determine record type from IP format
    {type, rdata} = classify_ip(ip)

    record = %{
      type: type,
      rdata: rdata,
      dns_ttl: ttl,
      source: :dhcp,
      source_ref: source_key,
      created_at: System.system_time(:second),
      updated_at: System.system_time(:second)
    }

    # Create forward record
    case DynDns.put(fqdn, record, ttl: ttl) do
      :ok ->
        Logger.debug("DynDnsUpdater: created #{type} record #{fqdn} → #{inspect(rdata)}")

      {:error, reason} ->
        Logger.warning("DynDnsUpdater: failed to create #{fqdn}: #{inspect(reason)}")
    end

    # Create reverse PTR record
    case build_arpa(ip) do
      {:ok, arpa} ->
        DynDns.put_ptr(arpa, fqdn, ttl: ttl)

      :error ->
        :ok
    end
  end

  defp handle_renew(hostname, ip, lease, state) do
    fqdn = build_fqdn(hostname, state.domain)
    ttl = Map.get(lease, :lease_duration, 3600)
    {type, rdata} = classify_ip(ip)

    record = %{
      type: type,
      rdata: rdata,
      dns_ttl: ttl,
      source: :dhcp,
      source_ref: "",
      created_at: System.system_time(:second),
      updated_at: System.system_time(:second)
    }

    DynDns.put(fqdn, record, ttl: ttl)
  end

  defp handle_release(hostname, state) do
    fqdn = build_fqdn(hostname, state.domain)

    case DynDns.delete(fqdn) do
      :ok ->
        Logger.debug("DynDnsUpdater: deleted DNS records for #{fqdn}")

      {:error, reason} ->
        Logger.warning("DynDnsUpdater: failed to delete #{fqdn}: #{inspect(reason)}")
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────

  defp build_fqdn(hostname, domain) do
    hostname = String.trim_trailing(hostname, ".")
    domain = String.trim_trailing(domain, ".")
    "#{hostname}.#{domain}."
  end

  defp classify_ip({_, _, _, _} = ip), do: {:a, ip}
  defp classify_ip({_, _, _, _, _, _, _, _} = ip), do: {:aaaa, ip}

  defp classify_ip(ip) when is_binary(ip) do
    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, {_, _, _, _} = parsed} -> {:a, parsed}
      {:ok, {_, _, _, _, _, _, _, _} = parsed} -> {:aaaa, parsed}
      _ -> {:a, ip}
    end
  end

  defp classify_ip(ip), do: {:a, ip}

  defp build_arpa({a, b, c, d}), do: {:ok, "#{d}.#{c}.#{b}.#{a}.in-addr.arpa"}

  defp build_arpa({_, _, _, _, _, _, _, _} = ipv6) do
    import Bitwise

    nibbles =
      ipv6
      |> Tuple.to_list()
      |> Enum.flat_map(fn word ->
        [word >>> 12 &&& 0xF, word >>> 8 &&& 0xF, word >>> 4 &&& 0xF, word &&& 0xF]
      end)
      |> Enum.reverse()
      |> Enum.map(&Integer.to_string(&1, 16))
      |> Enum.join(".")

    {:ok, "#{nibbles}.ip6.arpa"}
  end

  defp build_arpa(_), do: :error

  defp subscribe_to_bridge(state) do
    case EventBridge.subscribe(@lease_event_pattern) do
      {:ok, ref} ->
        mon = Process.monitor(Process.whereis(EventBridge))
        %{state | subscription_ref: ref, bridge_monitor: mon}

      _ ->
        Logger.warning("DynDnsUpdater: failed to subscribe to EventBridge, retrying")
        Process.send_after(self(), :resubscribe, @resubscribe_delay_ms)
        state
    end
  rescue
    e ->
      Logger.warning("DynDnsUpdater: EventBridge subscribe error: #{inspect(e)}")
      Process.send_after(self(), :resubscribe, @resubscribe_delay_ms)
      state
  end
end
