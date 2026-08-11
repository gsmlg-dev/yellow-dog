defmodule YellowDog.Console.DhcpLive.ManagementSupport do
  @moduledoc false

  alias YellowDog.Console.ManagementResult
  alias YellowDog.ManagementCore
  alias YellowDog.Sync.Digest

  @families [:ipv4, :ipv6]

  def family_wire(family) when family in @families, do: Atom.to_string(family)
  def family_label(:ipv4), do: "DHCPv4"
  def family_label(:ipv6), do: "DHCPv6"
  def service_type(:ipv4), do: :dhcpv4
  def service_type(:ipv6), do: :dhcpv6

  def subscribe(socket, server_id) do
    if Phoenix.LiveView.connected?(socket) and
         socket.assigns[:subscribed_server_id] != server_id do
      if old_id = socket.assigns[:subscribed_server_id] do
        Phoenix.PubSub.unsubscribe(YellowDog.Console.PubSub, "management:server:#{old_id}")
      end

      Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, "management:server:#{server_id}")
    end

    Phoenix.Component.assign(socket, :subscribed_server_id, server_id)
  end

  def refresh_selected_server(socket, server_id) do
    case ManagementCore.get_server(server_id) do
      {:ok, server} ->
        Phoenix.Component.assign(socket,
          selected_server: server,
          service_online?: server.status in [:online, "online"],
          snapshot_observed_at: server.last_seen_at
        )

      _error ->
        socket
    end
  end

  def items(%ManagementResult{status: :ok, value: %{"items" => items}}, family)
      when is_list(items) and family in @families do
    family = family_wire(family)
    Enum.filter(items, &match?(%{"family" => ^family}, &1))
  end

  def items(_result, _family), do: []

  def service_running?(
        %ManagementResult{
          status: :ok,
          value: %{"family" => family, "status" => "running"}
        },
        family_atom
      )
      when family_atom in @families,
      do: family == family_wire(family_atom)

  def service_running?(_result, _family), do: false

  def first_error(results) do
    Enum.find_value(results, fn
      %ManagementResult{status: :error} = result -> result
      _result -> nil
    end)
  end

  def cached_observed_at(results, fallback) do
    if cached?(results) do
      Enum.find_value(results, fallback, fn
        %ManagementResult{source: :cache, observed_at: observed_at} -> observed_at
        _result -> nil
      end)
    end
  end

  def cached?(results), do: Enum.any?(results, &match?(%ManagementResult{source: :cache}, &1))

  def mutable(%{assigns: %{service_online?: true, commands_enabled?: true}}), do: :ok

  def mutable(%{assigns: %{service_online?: true}}),
    do: {:error, "A current management snapshot is unavailable; commands are disabled"}

  def mutable(_socket),
    do: {:error, "The selected Server is offline; commands are disabled"}

  def create_options,
    do: [expected_revision: nil, idempotency_key: Ecto.UUID.generate()]

  def command_options(resource) when is_map(resource) do
    case Digest.calculate(resource) do
      {:ok, revision} ->
        [expected_revision: revision, idempotency_key: Ecto.UUID.generate()]

      {:error, _error} ->
        nil
    end
  end

  def command_options(_resource), do: nil

  def pool_views(items) when is_list(items) do
    Enum.map(items, fn resource ->
      lease_seconds = resource["lease_seconds"]

      %{
        name: resource["pool_id"],
        network: resource["subnet"],
        range_start: resource["start_address"],
        range_end: resource["end_address"],
        lease_time: lease_seconds,
        preferred_lifetime: lease_seconds,
        valid_lifetime: lease_seconds,
        gateway: nil,
        dns_servers: [],
        resource: resource
      }
    end)
  end

  def lease_views(items) when is_list(items) do
    Enum.map(items, fn resource ->
      %{
        lease_id: resource["lease_id"],
        address: resource["address"],
        state: resource["state"],
        resource: resource
      }
    end)
  end

  def activity_views(items) when is_list(items) do
    Enum.map(items, fn resource ->
      %{
        activity_id: resource["activity_id"],
        action: resource["action"],
        occurred_at: resource["occurred_at"],
        resource: resource
      }
    end)
  end

  def find_pool(pools, pool_id), do: Enum.find(pools, &(&1.name == pool_id))
  def find_lease(leases, lease_id), do: Enum.find(leases, &(&1.lease_id == lease_id))

  def put_pool(pools, resource) when is_list(pools) and is_map(resource) do
    pool = resource |> List.wrap() |> pool_views() |> List.first()

    pools
    |> Enum.reject(&(&1.name == pool.name))
    |> Kernel.++([pool])
    |> Enum.sort_by(& &1.name)
  end

  def delete_pool(pools, pool_id), do: Enum.reject(pools, &(&1.name == pool_id))

  def release_lease(leases, lease_id) do
    Enum.map(leases, fn
      %{lease_id: ^lease_id} = lease -> %{lease | state: "released", resource: nil}
      lease -> lease
    end)
  end

  def filter_pools(pools, ""), do: pools

  def filter_pools(pools, query) do
    query = String.downcase(query)

    Enum.filter(pools, fn pool ->
      String.contains?(String.downcase(pool.name), query) or
        String.contains?(String.downcase(pool.network), query)
    end)
  end

  def filter_leases(leases, search, state) do
    leases
    |> Enum.filter(fn lease ->
      search == "" or
        String.contains?(String.downcase(lease.lease_id), String.downcase(search)) or
        String.contains?(String.downcase(lease.address), String.downcase(search))
    end)
    |> Enum.filter(fn lease -> state == "all" or lease.state == state end)
  end

  def filter_activity(entries, search, action) do
    entries
    |> Enum.filter(fn entry ->
      search == "" or
        String.contains?(String.downcase(entry.activity_id), String.downcase(search)) or
        String.contains?(String.downcase(entry.action), String.downcase(search))
    end)
    |> Enum.filter(fn entry -> action == "all" or entry.action == action end)
  end

  def format_observed_at(%DateTime{} = datetime),
    do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S UTC")

  def format_observed_at(value) when is_binary(value), do: value
  def format_observed_at(_value), do: "unknown"
end
