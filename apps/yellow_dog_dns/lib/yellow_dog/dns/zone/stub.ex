defmodule YellowDog.Dns.Zone.Stub do
  @moduledoc """
  Stub zone process.

  A stub zone holds NS records for a zone and delegates queries
  to the authoritative servers listed in those NS records.

  ## Features

  - Holds NS records for delegation
  - Queries authoritative servers directly
  - Caches NS glue records
  - Round-robin selection of NS servers
  - Timeout and retry handling

  ## Usage

      # Start a stub zone for example.com
      {:ok, pid} = YellowDog.Dns.Zone.Stub.start_link(
        name: "example.com",
        ns_records: ["ns1.example.com", "ns2.example.com"],
        glue_records: %{
          "ns1.example.com" => {192, 168, 1, 1},
          "ns2.example.com" => {192, 168, 1, 2}
        }
      )

      # Resolve a query
      {:ok, response} = YellowDog.Dns.Zone.Stub.resolve(pid, query)
  """

  use GenServer

  alias YellowDog.Dns.Zone.Behaviour

  @behaviour Behaviour

  alias YellowDog.Telemetry

  @default_timeout 5000
  @default_retries 2
  @default_port 53

  @type t :: %__MODULE__{
          name: String.t(),
          view_name: String.t(),
          ns_records: [String.t()],
          glue_records: map(),
          socket: :gen_udp.socket() | nil,
          timeout: non_neg_integer(),
          retries: non_neg_integer(),
          current_ns: non_neg_integer(),
          query_count: non_neg_integer(),
          success_count: non_neg_integer(),
          error_count: non_neg_integer(),
          pending: map(),
          created_at: DateTime.t()
        }

  defstruct [
    :name,
    :view_name,
    :socket,
    :created_at,
    ns_records: [],
    glue_records: %{},
    timeout: @default_timeout,
    retries: @default_retries,
    current_ns: 0,
    query_count: 0,
    success_count: 0,
    error_count: 0,
    pending: %{}
  ]

  # Client API

  @doc """
  Starts a stub zone process.

  ## Options

  - `:name` - Zone name (required)
  - `:view_name` - View name (default: "default")
  - `:ns_records` - List of NS server hostnames
  - `:glue_records` - Map of hostname to IP address for NS servers
  - `:timeout` - Query timeout in ms (default: 5000)
  - `:retries` - Number of retries (default: 2)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    zone_name = Keyword.fetch!(opts, :name)
    view_name = Keyword.get(opts, :view_name, "default")
    GenServer.start_link(__MODULE__, opts, name: Behaviour.zone_via_tuple(view_name, :stub, zone_name))
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

  @doc """
  Gets the NS records for this stub zone.
  """
  @spec get_ns_records(pid()) :: [String.t()]
  def get_ns_records(pid) do
    GenServer.call(pid, :get_ns_records)
  end

  @doc """
  Adds or updates a glue record for an NS server.
  """
  @spec add_glue_record(pid(), String.t(), :inet.ip_address()) :: :ok
  def add_glue_record(pid, hostname, ip) do
    GenServer.call(pid, {:add_glue_record, hostname, ip})
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    zone_name = Keyword.fetch!(opts, :name)
    view_name = Keyword.get(opts, :view_name, "default")
    ns_records = Keyword.get(opts, :ns_records, [])
    glue_records = parse_glue_records(Keyword.get(opts, :glue_records, %{}))
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    retries = Keyword.get(opts, :retries, @default_retries)

    # Open UDP socket for querying NS servers
    {:ok, socket} = :gen_udp.open(0, [:binary, active: true])

    state = %__MODULE__{
      name: zone_name,
      view_name: view_name,
      ns_records: ns_records,
      glue_records: glue_records,
      socket: socket,
      timeout: timeout,
      retries: retries,
      created_at: DateTime.utc_now()
    }

    Telemetry.info("Stub zone started", %{
      name: zone_name,
      ns_count: length(ns_records),
      glue_count: map_size(glue_records)
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
  def handle_call(:get_ns_records, _from, state) do
    {:reply, state.ns_records, state}
  end

  @impl true
  def handle_call({:add_glue_record, hostname, ip}, _from, state) do
    glue_records = Map.put(state.glue_records, String.downcase(hostname), ip)
    {:reply, :ok, %{state | glue_records: glue_records}}
  end

  @impl true
  def handle_call({:resolve, query}, from, state) do
    state = %{state | query_count: state.query_count + 1}

    # Get available NS servers with glue records
    available_ns = get_available_ns_servers(state)

    case available_ns do
      [] ->
        Telemetry.warning("Stub zone has no available NS servers", %{
          zone: state.name,
          ns_records: state.ns_records
        })

        {:reply, {:error, :no_ns_servers}, state}

      servers ->
        # Select NS server (round-robin)
        {ns_ip, state} = select_ns_server(state, servers)

        # Send query to NS server
        case send_query(state, ns_ip, query) do
          :ok ->
            # Store pending request
            query_id = query.header.id
            timer_ref = Process.send_after(self(), {:timeout, query_id}, state.timeout)

            pending = %{
              from: from,
              query: query,
              ns_ip: ns_ip,
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
    ns_records = Keyword.get(config, :ns_records, state.ns_records)
    glue_records = parse_glue_records(Keyword.get(config, :glue_records, state.glue_records))
    timeout = Keyword.get(config, :timeout, state.timeout)
    retries = Keyword.get(config, :retries, state.retries)

    new_state = %{
      state
      | ns_records: ns_records,
        glue_records: glue_records,
        timeout: timeout,
        retries: retries
    }

    Telemetry.info("Stub zone reloaded", %{name: state.name})

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{
      name: state.name,
      type: :stub,
      ns_count: length(state.ns_records),
      ns_records: state.ns_records,
      glue_count: map_size(state.glue_records),
      available_ns: length(get_available_ns_servers(state)),
      query_count: state.query_count,
      success_count: state.success_count,
      error_count: state.error_count,
      pending_count: map_size(state.pending),
      created_at: state.created_at
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

          Telemetry.debug("Stub zone query completed", %{
            zone: state.name,
            ns_ip: format_ip(ip),
            port: port,
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
          # Retry with next NS server
          available_ns = get_available_ns_servers(state)

          if available_ns != [] do
            {ns_ip, state} = select_ns_server(%{state | pending: remaining}, available_ns)

            case send_query(state, ns_ip, pending.query) do
              :ok ->
                timer_ref = Process.send_after(self(), {:timeout, query_id}, state.timeout)

                new_pending = %{
                  pending
                  | ns_ip: ns_ip,
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
            GenServer.reply(pending.from, {:error, :servfail})
            state = %{state | pending: remaining, error_count: state.error_count + 1}
            {:noreply, state}
          end
        else
          # No more retries
          Telemetry.warning("Stub zone query timeout", %{
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
    if state.socket do
      :gen_udp.close(state.socket)
    end

    :ok
  end

  # Private Functions

  defp parse_glue_records(glue_records) when is_map(glue_records) do
    Map.new(glue_records, fn {hostname, ip} ->
      {String.downcase(to_string(hostname)), parse_ip(ip)}
    end)
  end

  defp parse_glue_records(_), do: %{}

  defp parse_ip(ip) when is_tuple(ip), do: ip

  defp parse_ip(ip) when is_binary(ip) do
    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, parsed} -> parsed
      _ -> nil
    end
  end

  defp parse_ip(_), do: nil

  defp get_available_ns_servers(state) do
    state.ns_records
    |> Enum.map(fn ns ->
      hostname = String.downcase(ns)
      Map.get(state.glue_records, hostname)
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp select_ns_server(state, servers) do
    index = rem(state.current_ns, length(servers))
    ns_ip = Enum.at(servers, index)
    {ns_ip, %{state | current_ns: state.current_ns + 1}}
  end

  defp send_query(state, ns_ip, query) do
    data = DNS.to_iodata(query)
    :gen_udp.send(state.socket, ns_ip, @default_port, data)
  end

  defp format_ip(ip) when is_tuple(ip) do
    :inet.ntoa(ip) |> to_string()
  end

  defp format_ip(ip), do: inspect(ip)

end
