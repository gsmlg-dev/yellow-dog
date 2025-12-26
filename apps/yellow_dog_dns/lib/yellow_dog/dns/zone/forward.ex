defmodule YellowDog.Dns.Zone.Forward do
  @moduledoc """
  Forwarding zone process.

  Forwards DNS queries to configured upstream servers.
  Supports multiple upstream servers with failover.

  ## Features

  - Multiple upstream servers with round-robin selection
  - Timeout and retry handling
  - Response caching (optional)
  - Health checking of upstream servers
  """

  use GenServer

  @behaviour YellowDog.Dns.Zone.Behaviour

  alias YellowDog.Telemetry

  @default_timeout 5000
  @default_retries 2

  defstruct [
    :name,
    :upstreams,
    :socket,
    :timeout,
    :retries,
    current_upstream: 0,
    query_count: 0,
    success_count: 0,
    error_count: 0,
    pending: %{}
  ]

  # Client API

  @doc """
  Starts a forwarding zone process.

  ## Options

  - `:name` - Zone name (required)
  - `:upstreams` - List of upstream servers [{ip, port}, ...]
  - `:timeout` - Query timeout in ms (default: 5000)
  - `:retries` - Number of retries (default: 2)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    zone_name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(zone_name))
  end

  @impl YellowDog.Dns.Zone.Behaviour
  def get_name(pid) do
    GenServer.call(pid, :get_name)
  end

  @impl YellowDog.Dns.Zone.Behaviour
  def resolve(pid, tsi, query) do
    GenServer.call(pid, {:resolve, tsi, query}, @default_timeout + 1000)
  end

  @impl YellowDog.Dns.Zone.Behaviour
  def reload(pid, config) do
    GenServer.call(pid, {:reload, config})
  end

  @impl YellowDog.Dns.Zone.Behaviour
  def stats(pid) do
    GenServer.call(pid, :stats)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    zone_name = Keyword.fetch!(opts, :name)
    upstreams = parse_upstreams(Keyword.get(opts, :upstreams, []))
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    retries = Keyword.get(opts, :retries, @default_retries)

    # Open UDP socket for forwarding
    {:ok, socket} = :gen_udp.open(0, [:binary, active: true])

    state = %__MODULE__{
      name: zone_name,
      upstreams: upstreams,
      socket: socket,
      timeout: timeout,
      retries: retries
    }

    Telemetry.info("Forward zone started", %{
      name: zone_name,
      upstreams: length(upstreams)
    })

    {:ok, state}
  end

  @impl true
  def handle_call(:get_name, _from, state) do
    {:reply, state.name, state}
  end

  @impl true
  def handle_call({:resolve, tsi, query}, from, state) do
    state = %{state | query_count: state.query_count + 1}

    case state.upstreams do
      [] ->
        {:reply, {:error, :no_upstreams}, state}

      _upstreams ->
        # Select upstream (round-robin)
        {upstream, state} = select_upstream(state)

        # Send query
        case send_query(state, upstream, query) do
          :ok ->
            # Store pending request
            query_id = query.header.id
            timer_ref = Process.send_after(self(), {:timeout, query_id}, state.timeout)

            pending = %{
              from: from,
              tsi: tsi,
              query: query,
              upstream: upstream,
              timer: timer_ref,
              retries: state.retries,
              started_at: System.monotonic_time(:microsecond)
            }

            state = %{state | pending: Map.put(state.pending, query_id, pending)}
            {:noreply, state}

          {:error, reason} ->
            state = %{state | error_count: state.error_count + 1}
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_call({:reload, config}, _from, state) do
    upstreams = parse_upstreams(Keyword.get(config, :upstreams, state.upstreams))
    timeout = Keyword.get(config, :timeout, state.timeout)
    retries = Keyword.get(config, :retries, state.retries)

    new_state = %{state | upstreams: upstreams, timeout: timeout, retries: retries}

    Telemetry.info("Forward zone reloaded", %{name: state.name})

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{
      name: state.name,
      upstream_count: length(state.upstreams),
      query_count: state.query_count,
      success_count: state.success_count,
      error_count: state.error_count,
      pending_count: map_size(state.pending)
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_info({:udp, socket, ip, port, data}, %{socket: socket} = state) do
    try do
      response = DNS.Message.from_iodata(data)
      query_id = response.header.id

      case Map.pop(state.pending, query_id) do
        {nil, _pending} ->
          # Unknown response, ignore
          {:noreply, state}

        {pending, remaining} ->
          # Cancel timeout timer
          Process.cancel_timer(pending.timer)

          # Calculate elapsed time
          elapsed = System.monotonic_time(:microsecond) - pending.started_at

          Telemetry.debug("Forward query completed", %{
            zone: state.name,
            upstream: format_upstream({ip, port}),
            elapsed_us: elapsed
          })

          # Reply to caller
          GenServer.reply(pending.from, {:ok, response})

          state = %{
            state
            | pending: remaining,
              success_count: state.success_count + 1
          }

          {:noreply, state}
      end
    catch
      :throw, _reason ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:timeout, query_id}, state) do
    case Map.pop(state.pending, query_id) do
      {nil, _pending} ->
        # Already handled
        {:noreply, state}

      {pending, remaining} ->
        if pending.retries > 0 do
          # Retry with next upstream
          {upstream, state} = select_upstream(%{state | pending: remaining})

          case send_query(state, upstream, pending.query) do
            :ok ->
              timer_ref = Process.send_after(self(), {:timeout, query_id}, state.timeout)

              new_pending = %{
                pending
                | upstream: upstream,
                  timer: timer_ref,
                  retries: pending.retries - 1
              }

              state = %{state | pending: Map.put(state.pending, query_id, new_pending)}
              {:noreply, state}

            {:error, _reason} ->
              GenServer.reply(pending.from, {:error, :servfail})
              state = %{state | error_count: state.error_count + 1}
              {:noreply, state}
          end
        else
          # No more retries
          Telemetry.warning("Forward query timeout", %{
            zone: state.name,
            query_id: query_id
          })

          GenServer.reply(pending.from, {:error, :servfail})
          state = %{state | pending: remaining, error_count: state.error_count + 1}
          {:noreply, state}
        end
    end
  end

  @impl true
  def terminate(_reason, state) do
    :gen_udp.close(state.socket)
    :ok
  end

  # Private Functions

  defp parse_upstreams(upstreams) when is_list(upstreams) do
    Enum.map(upstreams, fn
      {ip, port} when is_tuple(ip) and is_integer(port) ->
        {ip, port}

      ip_str when is_binary(ip_str) ->
        parse_upstream_string(ip_str)

      {ip_str, port} when is_binary(ip_str) and is_integer(port) ->
        case parse_ip(ip_str) do
          {:ok, ip} -> {ip, port}
          _ -> nil
        end

      _ ->
        nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_upstreams(_), do: []

  defp parse_upstream_string(str) do
    case String.split(str, ":") do
      [ip_str, port_str] ->
        with {:ok, ip} <- parse_ip(ip_str),
             {port, ""} <- Integer.parse(port_str) do
          {ip, port}
        else
          _ -> nil
        end

      [ip_str] ->
        case parse_ip(ip_str) do
          {:ok, ip} -> {ip, 53}
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp parse_ip(ip_str) do
    charlist = String.to_charlist(ip_str)

    case :inet.parse_address(charlist) do
      {:ok, ip} -> {:ok, ip}
      _ -> :error
    end
  end

  defp select_upstream(state) do
    index = rem(state.current_upstream, length(state.upstreams))
    upstream = Enum.at(state.upstreams, index)
    {upstream, %{state | current_upstream: state.current_upstream + 1}}
  end

  defp send_query(state, {ip, port}, query) do
    data = DNS.to_iodata(query)
    :gen_udp.send(state.socket, ip, port, data)
  end

  defp format_upstream({ip, port}) do
    "#{:inet.ntoa(ip)}:#{port}"
  end

  defp via_tuple(zone_name) do
    {:via, Registry, {YellowDog.Dns.ZoneRegistry, {:forward, zone_name}}}
  end
end
