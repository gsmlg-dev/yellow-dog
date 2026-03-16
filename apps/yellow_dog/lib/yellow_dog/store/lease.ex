defmodule YellowDog.Store.Lease do
  @moduledoc """
  DHCP lease lifecycle management facade over Concord.

  All functions take a `protocol` (`:v4` or `:v6`) and a client identifier
  (MAC address for v4, DUID for v6). Keys are encoded via `YellowDog.Store.Key`.

  State machine: offered -> bound -> renewing -> released/declined
  All state transitions use compare-and-swap (CAS) to prevent races.
  """

  alias YellowDog.Store.Key

  @type protocol :: :v4 | :v6
  @type client_id :: String.t()
  @type ip :: :inet.ip_address()
  @type lease :: map()

  @transition_event [:yellow_dog, :store, :lease, :transition]
  @operation_event [:yellow_dog, :store, :operation, :stop]

  @released_ttl 60

  # --- Public API ---

  @doc """
  Create a lease in `:offered` state.

  Uses CAS `put_if expected: nil` to prevent duplicate offers.
  Re-offers over stale (expired) offers are allowed by retrying
  with a condition that accepts nil or an existing `:offered` state.
  """
  @spec offer(protocol, client_id, ip, keyword()) :: :ok | {:error, term()}
  def offer(protocol, client_id, ip, opts \\ []) do
    key = Key.lease(protocol, client_id)
    now = System.system_time(:second)

    lease = %{
      ip: ip,
      state: :offered,
      xid: Keyword.get(opts, :xid),
      hostname: Keyword.get(opts, :hostname),
      lease_duration: Keyword.get(opts, :lease_duration, 3600),
      lease_start: now,
      subnet: Keyword.get(opts, :subnet),
      server_id: Keyword.get(opts, :server_id),
      interface: Keyword.get(opts, :interface),
      options: Keyword.get(opts, :options, %{}),
      renewed_at: nil,
      version: 1
    }

    ttl = lease.lease_duration

    result =
      Concord.put_if(key, lease,
        condition: fn
          nil -> true
          %{state: :offered} -> true
          _other -> false
        end
      )

    case result do
      :ok ->
        set_ttl(key, lease, ttl)
        emit_transition(client_id, nil, :offered, ip)
        emit_operation(:lease, :put_if, key)
        :ok

      {:error, :condition_failed} ->
        {:error, :already_exists}

      error ->
        error
    end
  end

  @doc """
  Transition a lease from `:offered` to `:bound`.

  CAS validates that the current state is `:offered` and the transaction ID matches.
  """
  @spec bind(protocol, client_id, integer()) :: :ok | {:error, term()}
  def bind(protocol, client_id, xid) do
    key = Key.lease(protocol, client_id)

    result =
      Concord.put_if(key, nil,
        condition: fn
          %{state: :offered, xid: ^xid} = lease ->
            {:update,
             %{
               lease
               | state: :bound,
                 lease_start: System.system_time(:second),
                 version: lease.version + 1
             }}

          %{state: :offered} ->
            false

          nil ->
            false

          _other ->
            false
        end
      )

    case result do
      :ok ->
        emit_transition(client_id, :offered, :bound, nil)
        emit_operation(:lease, :put_if, key)
        :ok

      {:error, :condition_failed} ->
        {:error, :invalid_transition}

      error ->
        error
    end
  end

  @doc """
  Transition a lease from `:bound` or `:renewing` to `:renewing`.

  Updates the TTL to the new duration.
  """
  @spec renew(protocol, client_id, pos_integer()) :: :ok | {:error, term()}
  def renew(protocol, client_id, duration) do
    key = Key.lease(protocol, client_id)
    now = System.system_time(:second)

    result =
      Concord.put_if(key, nil,
        condition: fn
          %{state: state} = lease when state in [:bound, :renewing] ->
            {:update,
             %{
               lease
               | state: :renewing,
                 renewed_at: now,
                 lease_duration: duration,
                 version: lease.version + 1
             }}

          _other ->
            false
        end
      )

    case result do
      :ok ->
        # Update the TTL for the renewed lease
        case Concord.get(key, consistency: :leader) do
          {:ok, lease} -> set_ttl(key, lease, duration)
          _ -> :ok
        end

        emit_transition(client_id, :bound, :renewing, nil)
        emit_operation(:lease, :put_if, key)
        :ok

      {:error, :condition_failed} ->
        {:error, :invalid_transition}

      error ->
        error
    end
  end

  @doc """
  Mark a lease as `:released` with a short TTL for cleanup.

  Does not delete the lease immediately -- it remains visible briefly
  so that event consumers can react to the release.
  """
  @spec release(protocol, client_id) :: :ok | {:error, term()}
  def release(protocol, client_id) do
    key = Key.lease(protocol, client_id)

    result =
      Concord.put_if(key, nil,
        condition: fn
          %{state: state} = lease when state in [:offered, :bound, :renewing] ->
            {:update, %{lease | state: :released, version: lease.version + 1}}

          nil ->
            false

          _other ->
            false
        end
      )

    case result do
      :ok ->
        case Concord.get(key, consistency: :leader) do
          {:ok, lease} -> set_ttl(key, lease, @released_ttl)
          _ -> :ok
        end

        emit_transition(client_id, nil, :released, nil)
        emit_operation(:lease, :put_if, key)
        :ok

      {:error, :condition_failed} ->
        {:error, :invalid_transition}

      error ->
        error
    end
  end

  @doc """
  Mark a lease as `:declined`. The IP should be flagged for avoidance.
  """
  @spec decline(protocol, client_id) :: :ok | {:error, term()}
  def decline(protocol, client_id) do
    key = Key.lease(protocol, client_id)

    result =
      Concord.put_if(key, nil,
        condition: fn
          %{state: state} = lease when state in [:offered, :bound, :renewing] ->
            {:update, %{lease | state: :declined, version: lease.version + 1}}

          nil ->
            false

          _other ->
            false
        end
      )

    case result do
      :ok ->
        emit_transition(client_id, nil, :declined, nil)
        emit_operation(:lease, :put_if, key)
        :ok

      {:error, :condition_failed} ->
        {:error, :invalid_transition}

      error ->
        error
    end
  end

  @doc """
  Look up a lease by client identifier with `:leader` consistency.
  """
  @spec get(protocol, client_id) :: {:ok, lease()} | {:error, :not_found}
  def get(protocol, client_id) do
    key = Key.lease(protocol, client_id)
    result = Concord.get(key, consistency: :leader)
    emit_operation(:lease, :get, key)
    result
  end

  @doc """
  Reverse lookup: find a lease by IP address across both v4 and v6 prefixes.
  """
  @spec by_ip(ip) :: {:ok, {protocol, client_id, lease()}} | {:error, :not_found}
  def by_ip(ip) do
    with {:error, :not_found} <- scan_prefix_for_ip(Key.lease_v4_prefix(), :v4, ip) do
      scan_prefix_for_ip(Key.lease_v6_prefix(), :v6, ip)
    end
  end

  @doc """
  List all leases in a given subnet. Uses prefix scan and filters by subnet field.
  """
  @spec list_by_subnet(String.t()) :: {:ok, [lease()]}
  def list_by_subnet(subnet) do
    v4 = scan_and_filter(Key.lease_v4_prefix(), fn lease -> lease.subnet == subnet end)
    v6 = scan_and_filter(Key.lease_v6_prefix(), fn lease -> lease.subnet == subnet end)

    {:ok, v4 ++ v6}
  end

  @doc """
  List all leases for a given protocol (`:v4` or `:v6`).
  """
  @spec list_by_protocol(protocol) :: {:ok, [{client_id, lease()}]}
  def list_by_protocol(protocol) do
    prefix = lease_prefix(protocol)

    case Concord.prefix_scan(prefix, []) do
      {:ok, entries} ->
        results =
          Enum.map(entries, fn {key, lease} ->
            id = String.replace_prefix(key, prefix, "")
            {id, lease}
          end)

        {:ok, results}

      error ->
        error
    end
  end

  # --- Private Helpers ---

  defp lease_prefix(:v4), do: Key.lease_v4_prefix()
  defp lease_prefix(:v6), do: Key.lease_v6_prefix()

  defp scan_prefix_for_ip(prefix, protocol, target_ip) do
    case Concord.prefix_scan(prefix, []) do
      {:ok, entries} ->
        case Enum.find(entries, fn {_key, lease} -> lease.ip == target_ip end) do
          {key, lease} ->
            id = String.replace_prefix(key, prefix, "")
            {:ok, {protocol, id, lease}}

          nil ->
            {:error, :not_found}
        end

      {:error, _} = error ->
        error
    end
  end

  defp scan_and_filter(prefix, filter_fn) do
    case Concord.prefix_scan(prefix, []) do
      {:ok, entries} ->
        entries
        |> Enum.filter(fn {_key, lease} -> filter_fn.(lease) end)
        |> Enum.map(fn {_key, lease} -> lease end)

      {:error, _} ->
        []
    end
  end

  defp set_ttl(key, lease, ttl) do
    Concord.put(key, lease, ttl: ttl)
  end

  defp emit_transition(client_id, from, to, ip) do
    :telemetry.execute(@transition_event, %{}, %{
      mac: client_id,
      from: from,
      to: to,
      ip: ip
    })
  end

  defp emit_operation(namespace, operation, key) do
    :telemetry.execute(@operation_event, %{}, %{
      namespace: namespace,
      operation: operation,
      key: key
    })
  end
end
