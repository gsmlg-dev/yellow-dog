defmodule YellowDog.Dns.RecursionWorker do
  @moduledoc """
  Short-lived worker for recursive DNS resolution.

  Each worker:
  - Opens its own ephemeral UDP socket
  - Performs synchronous iterative resolution
  - Closes socket on completion (success, error, or timeout)

  ## Resolution Process

  1. Start with root hints (root nameservers)
  2. Query root server for TLD nameservers
  3. Query TLD server for authoritative nameservers
  4. Query authoritative server for final answer
  5. Follow referrals until answer is found or max depth reached

  ## Error Handling

  - Socket errors: returns `{:error, :network_error}`
  - Max depth exceeded: returns `{:error, :max_recursion_depth}`
  - All servers failed: returns `{:error, :no_servers}`
  - Timeout: returns `{:error, :timeout}`
  """

  alias YellowDog.Telemetry
  alias DNS.Message
  alias DNS.Message.RCode

  @max_recursion_depth 10
  @default_query_timeout 5_000

  @doc """
  Performs recursive resolution for a DNS query.

  Opens a socket, resolves the query iteratively, and closes the socket.

  ## Options

  - `:root_servers` - List of root servers to start from
  - `:query_timeout` - Timeout per query in milliseconds

  ## Returns

  - `{:ok, response}` - Resolution successful
  - `{:error, reason}` - Resolution failed
  """
  @spec resolve(Message.t(), map() | keyword()) :: {:ok, Message.t()} | {:error, atom()}
  def resolve(query, opts \\ %{}) do
    opts = normalize_opts(opts)
    root_servers = Map.get(opts, :root_servers, default_root_servers())
    query_timeout = Map.get(opts, :query_timeout, @default_query_timeout)

    # Open ephemeral socket
    case Abyss.Transport.UDP.open(0, active: false) do
      {:ok, socket} ->
        try do
          do_resolve(socket, query, root_servers, query_timeout, 0)
        after
          Abyss.Transport.UDP.close(socket)
        end

      {:error, reason} ->
        Telemetry.warning("Failed to open recursion socket", %{reason: reason})
        {:error, :network_error}
    end
  end

  # Private resolution logic

  defp do_resolve(_socket, _query, _root_servers, _timeout, depth)
       when depth >= @max_recursion_depth do
    {:error, :max_recursion_depth}
  end

  defp do_resolve(socket, query, root_servers, timeout, depth) do
    case query.qdlist do
      [question | _] ->
        resolve_from_servers(socket, query, question, root_servers, timeout, depth)

      [] ->
        {:error, :format_error}
    end
  end

  defp resolve_from_servers(_socket, _query, _question, [], _timeout, _depth) do
    {:error, :no_servers}
  end

  defp resolve_from_servers(socket, query, question, [server | rest], timeout, depth) do
    case query_server(socket, query, server, timeout) do
      {:ok, response} ->
        handle_response(socket, query, question, response, timeout, depth)

      {:error, _reason} ->
        # Try next server
        resolve_from_servers(socket, query, question, rest, timeout, depth)
    end
  end

  defp query_server(socket, query, {ip, port}, timeout) do
    data = DNS.to_iodata(query)

    case Abyss.Transport.UDP.send(socket, ip, port, data) do
      :ok ->
        receive_response(socket, query.header.id, timeout)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp receive_response(socket, expected_id, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    receive_loop(socket, expected_id, deadline)
  end

  defp receive_loop(socket, expected_id, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :timeout}
    else
      case Abyss.Transport.UDP.recv(socket, 0, remaining) do
        {:ok, {_ip, _port, data}} ->
          try do
            response = DNS.Message.from_iodata(data)

            if response.header.id == expected_id do
              {:ok, response}
            else
              # Wrong ID, try again
              receive_loop(socket, expected_id, deadline)
            end
          catch
            :throw, reason ->
              {:error, reason}
          end

        {:error, :timeout} ->
          {:error, :timeout}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp handle_response(socket, query, question, response, timeout, depth) do
    rcode = normalize_rcode(response.header.rcode)

    cond do
      # Got an answer
      rcode == :noerror and response.anlist != [] ->
        {:ok, response}

      # NXDOMAIN - authoritative negative answer
      rcode == :nxdomain ->
        {:ok, response}

      # Got referral (no answers but has authority section with NS records)
      response.anlist == [] and has_ns_records?(response.nslist) ->
        follow_referral(socket, query, question, response, timeout, depth)

      # Server error
      rcode != :noerror ->
        {:error, rcode}

      # No useful response (empty NOERROR)
      true ->
        {:error, :no_data}
    end
  end

  defp follow_referral(socket, query, question, response, timeout, depth) do
    # Extract NS records and their glue
    ns_records = Enum.filter(response.nslist, fn r -> to_string(r.type) == "NS" end)

    # Get glue records (A/AAAA in additional section)
    glue_records = extract_glue(response.arlist)

    # Build server list from NS + glue
    servers = build_server_list(ns_records, glue_records)

    if servers == [] do
      # No glue, need to resolve NS hostnames first
      case resolve_ns_addresses(socket, ns_records, timeout, depth + 1) do
        {:ok, resolved_servers} ->
          resolve_from_servers(socket, query, question, resolved_servers, timeout, depth + 1)

        {:error, reason} ->
          {:error, reason}
      end
    else
      resolve_from_servers(socket, query, question, servers, timeout, depth + 1)
    end
  end

  defp has_ns_records?(records) do
    Enum.any?(records, fn r -> to_string(r.type) == "NS" end)
  end

  defp extract_glue(additional) do
    additional
    |> Enum.filter(fn r -> to_string(r.type) in ["A", "AAAA"] end)
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

  defp resolve_ns_addresses(_socket, [], _timeout, _depth) do
    {:error, :no_ns}
  end

  defp resolve_ns_addresses(socket, [ns | rest], timeout, depth) do
    if depth >= @max_recursion_depth do
      {:error, :max_recursion_depth}
    else
      ns_hostname = ns.rdata

      # Create query for NS hostname
      ns_query = build_query(ns_hostname, :a)

      case do_resolve(socket, ns_query, default_root_servers(), timeout, depth) do
        {:ok, response} ->
          addresses = for r <- response.anlist, to_string(r.type) == "A", do: {r.rdata, 53}

          if addresses == [] do
            resolve_ns_addresses(socket, rest, timeout, depth)
          else
            {:ok, addresses}
          end

        {:error, _reason} ->
          resolve_ns_addresses(socket, rest, timeout, depth)
      end
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
        rcode: RCode.no_error()
      },
      qdlist: [
        DNS.Message.Question.new(name, type, :in)
      ],
      anlist: [],
      nslist: [],
      arlist: []
    }
  end

  # Normalize rcode to atom for comparison
  defp normalize_rcode(:noerror), do: :noerror
  defp normalize_rcode(:nxdomain), do: :nxdomain
  defp normalize_rcode(%RCode{value: <<0::4>>}), do: :noerror
  defp normalize_rcode(%RCode{value: <<1::4>>}), do: :formerr
  defp normalize_rcode(%RCode{value: <<2::4>>}), do: :servfail
  defp normalize_rcode(%RCode{value: <<3::4>>}), do: :nxdomain
  defp normalize_rcode(%RCode{value: <<4::4>>}), do: :notimp
  defp normalize_rcode(%RCode{value: <<5::4>>}), do: :refused
  defp normalize_rcode(%RCode{} = rcode), do: rcode
  defp normalize_rcode(other), do: other

  defp normalize_opts(opts) when is_map(opts), do: opts
  defp normalize_opts(opts) when is_list(opts), do: Map.new(opts)

  defp default_root_servers do
    # Root servers - a.root-servers.net through m.root-servers.net
    [
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
  end
end
