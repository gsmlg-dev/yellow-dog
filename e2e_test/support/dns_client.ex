defmodule E2ETest.DnsClient do
  @moduledoc """
  DNS query helper for E2E tests.

  Uses the ex_dns library to build DNS messages and sends them via UDP
  to test DNS and mDNS servers.
  """

  alias DNS.Message
  alias DNS.Message.Header
  alias DNS.Message.Question

  @default_timeout 5_000

  @doc """
  Send a DNS query and receive the response.

  ## Parameters
  - `host` - Server IP address as tuple (e.g., {127, 0, 0, 1})
  - `port` - Server port number
  - `name` - Domain name to query (e.g., "example.com")
  - `type` - Record type atom (:A, :AAAA, :PTR, :SRV, :TXT, :MX, :NS, :SOA)
  - `opts` - Options keyword list
    - `:timeout` - Query timeout in ms (default: 5000)
    - `:rd` - Recursion desired flag (default: 1)

  ## Returns
  - `{:ok, %DNS.Message{}}` - Parsed DNS response
  - `{:error, reason}` - Error with reason
  """
  @spec query(:inet.ip_address(), :inet.port_number(), String.t(), atom(), keyword()) ::
          {:ok, Message.t()} | {:error, term()}
  def query(host, port, name, type, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    rd = Keyword.get(opts, :rd, 1)

    # Build query message
    message = build_query(name, type, rd)
    packet = DNS.to_iodata(message) |> IO.iodata_to_binary()

    # Open UDP socket
    socket_opts = [:binary, {:active, false}]

    socket_opts =
      if tuple_size(host) == 8 do
        # IPv6
        [:inet6 | socket_opts]
      else
        socket_opts
      end

    case :gen_udp.open(0, socket_opts) do
      {:ok, socket} ->
        result = send_and_receive(socket, host, port, packet, timeout)
        :gen_udp.close(socket)
        result

      {:error, reason} ->
        {:error, {:socket_open_failed, reason}}
    end
  end

  @doc """
  Query for an A record (IPv4 address).
  """
  @spec query_a(:inet.ip_address(), :inet.port_number(), String.t(), keyword()) ::
          {:ok, Message.t()} | {:error, term()}
  def query_a(host, port, name, opts \\ []) do
    query(host, port, name, :A, opts)
  end

  @doc """
  Query for an AAAA record (IPv6 address).
  """
  @spec query_aaaa(:inet.ip_address(), :inet.port_number(), String.t(), keyword()) ::
          {:ok, Message.t()} | {:error, term()}
  def query_aaaa(host, port, name, opts \\ []) do
    query(host, port, name, :AAAA, opts)
  end

  @doc """
  Query for a PTR record (used for mDNS service discovery).
  """
  @spec query_ptr(:inet.ip_address(), :inet.port_number(), String.t(), keyword()) ::
          {:ok, Message.t()} | {:error, term()}
  def query_ptr(host, port, name, opts \\ []) do
    query(host, port, name, :PTR, opts)
  end

  @doc """
  Query for an SRV record (service location).
  """
  @spec query_srv(:inet.ip_address(), :inet.port_number(), String.t(), keyword()) ::
          {:ok, Message.t()} | {:error, term()}
  def query_srv(host, port, name, opts \\ []) do
    query(host, port, name, :SRV, opts)
  end

  @doc """
  Query for a TXT record.
  """
  @spec query_txt(:inet.ip_address(), :inet.port_number(), String.t(), keyword()) ::
          {:ok, Message.t()} | {:error, term()}
  def query_txt(host, port, name, opts \\ []) do
    query(host, port, name, :TXT, opts)
  end

  @doc """
  Extract the response code from a DNS message.

  ## Returns
  - `:NOERROR` (0) - No error
  - `:FORMERR` (1) - Format error
  - `:SERVFAIL` (2) - Server failure
  - `:NXDOMAIN` (3) - Name does not exist
  - `:NOTIMP` (4) - Not implemented
  - `:REFUSED` (5) - Query refused
  - Integer for other codes
  """
  @spec get_rcode(Message.t()) :: atom() | integer()
  def get_rcode(%Message{header: header}) do
    rcode_value = header.rcode.value

    case rcode_value do
      0 -> :NOERROR
      1 -> :FORMERR
      2 -> :SERVFAIL
      3 -> :NXDOMAIN
      4 -> :NOTIMP
      5 -> :REFUSED
      n -> n
    end
  end

  @doc """
  Get answer records from a DNS message.
  """
  @spec get_answers(Message.t()) :: [DNS.Message.Record.t()]
  def get_answers(%Message{anlist: answers}) do
    answers
  end

  @doc """
  Check if the response indicates a successful query (NOERROR).
  """
  @spec success?(Message.t()) :: boolean()
  def success?(message) do
    get_rcode(message) == :NOERROR
  end

  @doc """
  Check if the response indicates the domain doesn't exist (NXDOMAIN).
  """
  @spec nxdomain?(Message.t()) :: boolean()
  def nxdomain?(message) do
    get_rcode(message) == :NXDOMAIN
  end

  # Private functions

  defp build_query(name, type, rd) do
    # Create header with random ID
    header = %Header{
      id: Header.generate_id(),
      qr: 0,
      opcode: DNS.Message.OpCode.new(0),
      aa: 0,
      tc: 0,
      rd: rd,
      ra: 0,
      z: 0,
      ad: 0,
      cd: 0,
      rcode: DNS.Message.RCode.new(0),
      qdcount: 1,
      ancount: 0,
      nscount: 0,
      arcount: 0
    }

    # Create question - use lowercase :in for DNS.Class.new/1
    question = Question.new(name, type_to_code(type), :in)

    %Message{
      header: header,
      qdlist: [question],
      anlist: [],
      nslist: [],
      arlist: []
    }
  end

  defp type_to_code(:A), do: 1
  defp type_to_code(:NS), do: 2
  defp type_to_code(:CNAME), do: 5
  defp type_to_code(:SOA), do: 6
  defp type_to_code(:PTR), do: 12
  defp type_to_code(:MX), do: 15
  defp type_to_code(:TXT), do: 16
  defp type_to_code(:AAAA), do: 28
  defp type_to_code(:SRV), do: 33
  defp type_to_code(:ANY), do: 255
  defp type_to_code(n) when is_integer(n), do: n
  defp type_to_code(type), do: raise("Unknown DNS type: #{inspect(type)}")

  defp send_and_receive(socket, host, port, packet, timeout) do
    case :gen_udp.send(socket, host, port, packet) do
      :ok ->
        receive_response(socket, timeout)

      {:error, reason} ->
        {:error, {:send_failed, reason}}
    end
  end

  defp receive_response(socket, timeout) do
    case :gen_udp.recv(socket, 0, timeout) do
      {:ok, {_ip, _port, response_data}} ->
        parse_response(response_data)

      {:error, :timeout} ->
        {:error, :timeout}

      {:error, reason} ->
        {:error, {:recv_failed, reason}}
    end
  end

  defp parse_response(data) when is_binary(data) do
    try do
      message = Message.from_iodata(data)
      {:ok, message}
    rescue
      e -> {:error, {:parse_failed, e}}
    catch
      :throw, error -> {:error, {:parse_failed, error}}
    end
  end
end
