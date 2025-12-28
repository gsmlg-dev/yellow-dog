defmodule YellowDog.Dns.RecursionController do
  @moduledoc """
  Handles recursive DNS resolution.

  The RecursionController performs iterative queries starting from root
  servers to resolve domain names that are not in local zones.

  ## Resolution Process

  1. Start with root hints (root nameservers)
  2. Query root server for TLD nameservers
  3. Query TLD server for authoritative nameservers
  4. Query authoritative server for final answer
  5. Follow referrals until answer is found or max depth reached

  ## Features

  - Iterative resolution from root
  - Referral following
  - Glue record handling
  - Query depth limiting
  - Response caching
  """

  use GenServer

  alias YellowDog.Telemetry
  alias DNS.Message

  @max_recursion_depth 10
  @query_timeout 5000
  @default_root_servers [
    # Root servers - a.root-servers.net through m.root-servers.net
    {{198, 41, 0, 4}, 53},
    {{199, 9, 14, 201}, 53},
    {{192, 33, 4, 12}, 53},
    {{199, 7, 91, 13}, 53},
    {{192, 203, 230, 10}, 53},
    {{192, 5, 5, 241}, 53},
    {{192, 112, 36, 4}, 53},
    {{198, 97, 190, 53}, 53},
    {{192, 36, 148, 17}, 53},
    {{192, 58, 128, 30}, 53},
    {{193, 0, 14, 129}, 53},
    {{199, 7, 83, 42}, 53},
    {{202, 12, 27, 33}, 53}
  ]

  defstruct [
    :view_name,
    :socket,
    :root_servers,
    pending: %{},
    query_count: 0,
    success_count: 0,
    error_count: 0
  ]

  # Client API

  @doc """
  Starts a RecursionController.

  ## Options

  - `:view_name` - Name of the parent view
  - `:root_servers` - Custom root server list (optional)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    view_name = Keyword.get(opts, :view_name, "default")
    GenServer.start_link(__MODULE__, opts, name: via_tuple(view_name))
  end

  @doc """
  Performs recursive resolution for a query.
  """
  @spec resolve(pid(), Message.t()) :: {:ok, Message.t()} | {:error, atom()}
  def resolve(pid, query) do
    GenServer.call(pid, {:resolve, query}, @query_timeout * @max_recursion_depth)
  end

  @doc """
  Returns recursion controller statistics.
  """
  @spec stats(pid()) :: map()
  def stats(pid) do
    GenServer.call(pid, :stats)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    view_name = Keyword.get(opts, :view_name, "default")
    root_servers = Keyword.get(opts, :root_servers, @default_root_servers)

    {:ok, socket} = :gen_udp.open(0, [:binary, active: true])

    state = %__MODULE__{
      view_name: view_name,
      socket: socket,
      root_servers: root_servers
    }

    Telemetry.info("RecursionController started", %{view: view_name})

    {:ok, state}
  end

  @impl true
  def handle_call({:resolve, query}, _from, state) do
    state = %{state | query_count: state.query_count + 1}

    # Start recursive resolution
    case do_recursive_resolve(state, query, 0) do
      {:ok, response} ->
        state = %{state | success_count: state.success_count + 1}
        {:reply, {:ok, response}, state}

      {:error, reason} ->
        state = %{state | error_count: state.error_count + 1}
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{
      view_name: state.view_name,
      query_count: state.query_count,
      success_count: state.success_count,
      error_count: state.error_count
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_info({:udp, _socket, _ip, _port, _data}, state) do
    # Handle async UDP responses if needed
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    :gen_udp.close(state.socket)
    :ok
  end

  # Private Functions

  defp do_recursive_resolve(_state, _query, depth) when depth >= @max_recursion_depth do
    {:error, :max_recursion_depth}
  end

  defp do_recursive_resolve(state, query, depth) do
    case query.qdlist do
      [question | _] ->
        # Start from root servers
        resolve_from_servers(state, query, question, state.root_servers, depth)

      [] ->
        {:error, :format_error}
    end
  end

  defp resolve_from_servers(_state, _query, _question, [], _depth) do
    {:error, :no_servers}
  end

  defp resolve_from_servers(state, query, question, [server | rest], depth) do
    case query_server(state, query, server) do
      {:ok, response} ->
        handle_response(state, query, question, response, depth)

      {:error, _reason} ->
        # Try next server
        resolve_from_servers(state, query, question, rest, depth)
    end
  end

  defp query_server(state, query, {ip, port}) do
    data = DNS.to_iodata(query)

    case :gen_udp.send(state.socket, ip, port, data) do
      :ok ->
        receive_response(state.socket, query.header.id)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp receive_response(socket, expected_id) do
    receive do
      {:udp, ^socket, _ip, _port, data} ->
        try do
          response = DNS.Message.from_iodata(data)

          if response.header.id == expected_id do
            {:ok, response}
          else
            # Wrong ID, try again
            receive_response(socket, expected_id)
          end
        catch
          :throw, reason ->
            {:error, reason}
        end
    after
      @query_timeout ->
        {:error, :timeout}
    end
  end

  defp handle_response(state, query, question, response, depth) do
    cond do
      # Got an answer
      response.header.rcode == :noerror and length(response.anlist) > 0 ->
        {:ok, response}

      # NXDOMAIN
      response.header.rcode == :nxdomain ->
        {:ok, response}

      # Got referral (no answers but has authority section with NS records)
      length(response.anlist) == 0 and has_ns_records?(response.nslist) ->
        follow_referral(state, query, question, response, depth)

      # Server error
      response.header.rcode != :noerror ->
        {:error, response.header.rcode}

      # No useful response
      true ->
        {:error, :no_data}
    end
  end

  defp follow_referral(state, query, question, response, depth) do
    # Extract NS records and their glue
    ns_records = Enum.filter(response.nslist, &(&1.type == :ns))

    # Get glue records (A/AAAA in additional section)
    glue_records = extract_glue(response.arlist)

    # Build server list from NS + glue
    servers = build_server_list(ns_records, glue_records)

    if Enum.empty?(servers) do
      # No glue, need to resolve NS hostnames first
      case resolve_ns_addresses(state, ns_records, depth + 1) do
        {:ok, resolved_servers} ->
          resolve_from_servers(state, query, question, resolved_servers, depth + 1)

        {:error, reason} ->
          {:error, reason}
      end
    else
      resolve_from_servers(state, query, question, servers, depth + 1)
    end
  end

  defp has_ns_records?(records) do
    Enum.any?(records, &(&1.type == :ns))
  end

  defp extract_glue(additional) do
    additional
    |> Enum.filter(&(&1.type in [:a, :aaaa]))
    |> Enum.group_by(& &1.name)
  end

  defp build_server_list(ns_records, glue_records) do
    Enum.flat_map(ns_records, fn ns ->
      ns_hostname = ns.rdata

      case Map.get(glue_records, ns_hostname, []) do
        [] ->
          []

        glue ->
          Enum.map(glue, fn record ->
            {record.rdata, 53}
          end)
      end
    end)
  end

  defp resolve_ns_addresses(_state, [], _depth) do
    {:error, :no_ns}
  end

  defp resolve_ns_addresses(state, [ns | rest], depth) do
    ns_hostname = ns.rdata

    # Create query for NS hostname
    ns_query = build_query(ns_hostname, :a)

    case do_recursive_resolve(state, ns_query, depth) do
      {:ok, response} ->
        addresses =
          response.anlist
          |> Enum.filter(&(&1.type == :a))
          |> Enum.map(&{&1.rdata, 53})

        if Enum.empty?(addresses) do
          resolve_ns_addresses(state, rest, depth)
        else
          {:ok, addresses}
        end

      {:error, _reason} ->
        resolve_ns_addresses(state, rest, depth)
    end
  end

  defp build_query(name, type) do
    %Message{
      header: %DNS.Message.Header{
        id: :rand.uniform(65535),
        qr: 0,
        opcode: :query,
        aa: 0,
        tc: 0,
        rd: 0,
        ra: 0,
        rcode: :noerror
      },
      qdlist: [
        DNS.Message.Question.new(name, type, :in)
      ],
      anlist: [],
      nslist: [],
      arlist: []
    }
  end

  defp via_tuple(view_name) do
    {:via, Registry, {YellowDog.Dns.RecursionRegistry, view_name}}
  end
end
