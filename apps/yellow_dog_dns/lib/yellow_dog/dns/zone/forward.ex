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

  ## Legacy API

  This module also provides a legacy struct-based API for configuration
  and validation, used by Zone.Manager for loading forward zones.
  """

  use GenServer

  alias YellowDog.Dns.IpFormat
  alias YellowDog.Dns.Zone.Behaviour

  @behaviour Behaviour

  alias YellowDog.Telemetry

  @default_timeout 5000
  @default_retries 2

  @type t :: %__MODULE__{
          name: String.t() | nil,
          view_name: String.t() | nil,
          upstreams: [{:inet.ip_address(), :inet.port_number()}] | nil,
          socket: :gen_udp.socket() | nil,
          timeout: non_neg_integer() | nil,
          retries: non_neg_integer() | nil,
          forwarders: [:inet.ip_address()] | nil,
          forward_mode: :only | :first | nil,
          timeout_ms: non_neg_integer() | nil,
          max_retries: non_neg_integer() | nil,
          current_upstream: non_neg_integer(),
          query_count: non_neg_integer(),
          success_count: non_neg_integer(),
          error_count: non_neg_integer(),
          pending: map()
        }

  defstruct [
    :name,
    :view_name,
    :upstreams,
    :socket,
    :timeout,
    :retries,
    # Legacy fields for struct-based API
    :forwarders,
    :forward_mode,
    :timeout_ms,
    :max_retries,
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
    view_name = Keyword.get(opts, :view_name, "default")

    GenServer.start_link(__MODULE__, opts,
      name: Behaviour.zone_via_tuple(view_name, :forward, zone_name)
    )
  end

  @impl YellowDog.Dns.Zone.Behaviour
  def get_name(pid) do
    GenServer.call(pid, :get_name)
  end

  @doc """
  Gets the view name this zone belongs to.
  """
  @spec get_view(pid()) :: String.t()
  def get_view(pid) do
    GenServer.call(pid, :get_view)
  end

  @impl YellowDog.Dns.Zone.Behaviour
  def resolve(pid, query) do
    GenServer.call(pid, {:resolve, query}, @default_timeout + 1000)
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
    view_name = Keyword.get(opts, :view_name, "default")
    upstreams = parse_upstreams(Keyword.get(opts, :upstreams, []))
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    retries = Keyword.get(opts, :retries, @default_retries)

    # Open UDP socket for forwarding
    {:ok, socket} = :gen_udp.open(0, [:binary, active: true])

    state = %__MODULE__{
      name: zone_name,
      view_name: view_name,
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
  def handle_call(:get_view, _from, state) do
    {:reply, state.view_name, state}
  end

  @impl true
  def handle_call({:resolve, query}, from, state) do
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
      upstreams: format_upstreams(state.upstreams),
      query_count: state.query_count,
      success_count: state.success_count,
      error_count: state.error_count,
      pending_count: map_size(state.pending)
    }

    {:reply, stats, state}
  end

  # Format upstreams back to string format for display/editing
  defp format_upstreams(upstreams) do
    Enum.map(upstreams, &format_upstream/1)
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
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    :gen_udp.close(state.socket)
    :ok
  end

  # Private Functions

  defp parse_upstreams(upstreams) when is_list(upstreams) do
    for upstream <- upstreams,
        parsed = parse_single_upstream(upstream),
        parsed != nil,
        do: parsed
  end

  defp parse_upstreams(_), do: []

  defp parse_single_upstream({ip, port}) when is_tuple(ip) and is_integer(port), do: {ip, port}
  defp parse_single_upstream(ip_str) when is_binary(ip_str), do: parse_upstream_string(ip_str)

  defp parse_single_upstream({ip_str, port}) when is_binary(ip_str) and is_integer(port) do
    case IpFormat.parse(ip_str) do
      {:ok, ip} -> {ip, port}
      _ -> nil
    end
  end

  defp parse_single_upstream(_), do: nil

  defp parse_upstream_string(str) do
    case String.split(str, ":") do
      [ip_str, port_str] ->
        with {:ok, ip} <- IpFormat.parse(ip_str),
             {port, ""} <- Integer.parse(port_str) do
          {ip, port}
        else
          _ -> nil
        end

      [ip_str] ->
        case IpFormat.parse(ip_str) do
          {:ok, ip} -> {ip, 53}
          _ -> nil
        end

      _ ->
        nil
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
    "#{IpFormat.format(ip)}:#{port}"
  end

  # ===========================================================================
  # Legacy Struct-Based API
  # ===========================================================================
  # These functions provide backwards compatibility for Zone.Manager and tests
  # that use the struct-based API for configuration.

  @doc """
  Creates a new forward zone struct (legacy API).

  ## Parameters
  - `name` - Zone name
  - `forwarders` - List of upstream server IP tuples
  - `opts` - Options: forward_mode, timeout_ms, max_retries
  """
  @spec new(String.t(), [tuple()], keyword()) :: t()
  def new(name, forwarders, opts \\ []) do
    %__MODULE__{
      name: name,
      forwarders: forwarders,
      forward_mode: Keyword.get(opts, :forward_mode, :only),
      timeout_ms: Keyword.get(opts, :timeout_ms, @default_timeout),
      max_retries: Keyword.get(opts, :max_retries, @default_retries)
    }
  end

  @doc """
  Validates a forward zone struct (legacy API).
  """
  @spec validate(t()) :: :ok | {:error, atom()}
  def validate(%__MODULE__{} = forward) do
    cond do
      is_nil(forward.name) or forward.name == "" ->
        {:error, :missing_name}

      is_nil(forward.forwarders) or forward.forwarders == [] ->
        {:error, :missing_forwarders}

      forward.forward_mode not in [:only, :first] ->
        {:error, :invalid_forward_mode}

      not is_integer(forward.timeout_ms) or forward.timeout_ms < 100 or
          forward.timeout_ms > 30_000 ->
        {:error, :invalid_timeout}

      not is_integer(forward.max_retries) or forward.max_retries < 0 or
          forward.max_retries > 10 ->
        {:error, :invalid_max_retries}

      true ->
        :ok
    end
  end

  @doc """
  Parses forward zone from config map (legacy API).
  """
  @spec parse_config(map()) :: {:ok, t()} | {:error, atom()}
  def parse_config(config) when is_map(config) do
    with {:ok, name} <- get_required(config, "name"),
         {:ok, forwarder_strs} <- get_required(config, "forwarders"),
         {:ok, forwarders} <- parse_forwarder_ips(forwarder_strs) do
      forward_mode =
        case Map.get(config, "forward_mode", "only") do
          "first" -> :first
          _ -> :only
        end

      forward =
        new(name, forwarders,
          forward_mode: forward_mode,
          timeout_ms: Map.get(config, "timeout_ms", @default_timeout),
          max_retries: Map.get(config, "max_retries", @default_retries)
        )

      {:ok, forward}
    end
  end

  @doc """
  Converts forward zone to storage metadata (legacy API).
  """
  @spec to_storage_metadata(t()) :: map()
  def to_storage_metadata(%__MODULE__{} = forward) do
    %{
      type: :forward,
      forwarders: forward.forwarders,
      forward_mode: forward.forward_mode,
      timeout_ms: forward.timeout_ms,
      max_retries: forward.max_retries,
      loaded_at: System.system_time(:second)
    }
  end

  @doc """
  Creates forward zone from storage metadata (legacy API).
  """
  @spec from_storage_metadata(String.t(), map()) :: {:ok, t()} | {:error, atom()}
  def from_storage_metadata(zone_name, metadata) do
    cond do
      Map.get(metadata, :type) != :forward ->
        {:error, :not_forward_zone}

      is_nil(metadata[:forwarders]) or metadata[:forwarders] == [] ->
        {:error, :missing_forwarders}

      true ->
        forward =
          new(zone_name, metadata[:forwarders],
            forward_mode: Map.get(metadata, :forward_mode, :only),
            timeout_ms: Map.get(metadata, :timeout_ms, @default_timeout),
            max_retries: Map.get(metadata, :max_retries, @default_retries)
          )

        {:ok, forward}
    end
  end

  # Legacy API helpers

  @valid_required_keys %{"name" => :missing_name, "forwarders" => :missing_forwarders}
  defp get_required(config, key) when is_map_key(@valid_required_keys, key) do
    case Map.get(config, key) do
      value when value in [nil, "", []] -> {:error, @valid_required_keys[key]}
      value -> {:ok, value}
    end
  end

  defp parse_forwarder_ips(forwarder_strs) when is_list(forwarder_strs) do
    result =
      Enum.reduce_while(forwarder_strs, {:ok, []}, fn str, {:ok, acc} ->
        case :inet.parse_address(String.to_charlist(str)) do
          {:ok, ip} -> {:cont, {:ok, [ip | acc]}}
          _ -> {:halt, {:error, :invalid_forwarders}}
        end
      end)

    case result do
      {:ok, ips} -> {:ok, Enum.reverse(ips)}
      error -> error
    end
  end

  defp parse_forwarder_ips(_), do: {:error, :invalid_forwarders}
end
