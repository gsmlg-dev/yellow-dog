defmodule YellowDog.Dns.Client do
  @moduledoc """
  DNS client for sending DNS queries.

  Uses `Abyss.Client` for UDP transport and `ex_dns` for message encoding/decoding.

  ## Usage

      # Simple query
      {:ok, response} = YellowDog.Dns.Client.query("example.com", :a, {8, 8, 8, 8})

      # Query with options
      {:ok, response} = YellowDog.Dns.Client.query("example.com", :mx, {8, 8, 8, 8},
        port: 53,
        timeout: 5000,
        recursion_desired: true
      )
  """

  @default_port 53
  @default_timeout 5000

  @typedoc "DNS record type"
  @type record_type :: :a | :aaaa | :mx | :ns | :txt | :cname | :soa | :ptr | :srv | atom()

  @typedoc "Query options"
  @type query_opts :: [
          port: :inet.port_number(),
          timeout: non_neg_integer(),
          recursion_desired: boolean(),
          source: :inet.ip_address()
        ]

  @doc """
  Send a DNS query and wait for response.

  ## Parameters

  - `name` - Domain name to query (e.g., "example.com")
  - `type` - Record type (:a, :aaaa, :mx, :ns, :txt, :cname, :soa, :ptr, :srv)
  - `server` - DNS server IP address
  - `opts` - Optional keyword list:
    - `:port` - Server port (default: 53)
    - `:timeout` - Timeout in milliseconds (default: 5000)
    - `:recursion_desired` - Set RD flag (default: true)
    - `:source` - Source IP address to bind

  ## Returns

  - `{:ok, %DNS.Message{}}` - Parsed DNS response
  - `{:error, :timeout}` - Query timed out
  - `{:error, reason}` - Other error

  ## Examples

      iex> YellowDog.Dns.Client.query("google.com", :a, {8, 8, 8, 8})
      {:ok, %DNS.Message{...}}

      iex> YellowDog.Dns.Client.query("example.com", :mx, {1, 1, 1, 1}, timeout: 2000)
      {:ok, %DNS.Message{...}}
  """
  @spec query(String.t(), record_type(), :inet.ip_address(), query_opts()) ::
          {:ok, DNS.Message.t()} | {:error, term()}
  def query(name, type, server, opts \\ []) do
    {request_binary, port, timeout, client_opts} = build_request(name, type, opts)

    case Abyss.Client.send_recv(server, port, request_binary, timeout, client_opts) do
      {:ok, response_binary} -> parse_response(response_binary)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Send a DNS query and return raw binary response.

  Useful when you want to handle parsing yourself or need the raw bytes.

  ## Parameters

  Same as `query/4`.

  ## Returns

  - `{:ok, binary}` - Raw DNS response bytes
  - `{:error, reason}` - Error
  """
  @spec query_raw(String.t(), record_type(), :inet.ip_address(), query_opts()) ::
          {:ok, binary()} | {:error, term()}
  def query_raw(name, type, server, opts \\ []) do
    {request_binary, port, timeout, client_opts} = build_request(name, type, opts)
    Abyss.Client.send_recv(server, port, request_binary, timeout, client_opts)
  end

  @doc """
  Send a pre-built DNS message.

  ## Parameters

  - `message` - `%DNS.Message{}` struct
  - `server` - DNS server IP address
  - `opts` - Optional keyword list (same as `query/4`)

  ## Returns

  - `{:ok, %DNS.Message{}}` - Parsed DNS response
  - `{:error, reason}` - Error
  """
  @spec send_message(DNS.Message.t(), :inet.ip_address(), query_opts()) ::
          {:ok, DNS.Message.t()} | {:error, term()}
  def send_message(message, server, opts \\ []) do
    port = Keyword.get(opts, :port, @default_port)
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    request_binary = DNS.to_iodata(message) |> IO.iodata_to_binary()
    client_opts = build_client_opts(opts)

    case Abyss.Client.send_recv(server, port, request_binary, timeout, client_opts) do
      {:ok, response_binary} ->
        parse_response(response_binary)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Build a serialized DNS request from name, type, and options
  defp build_request(name, type, opts) do
    port = Keyword.get(opts, :port, @default_port)
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    rd = if Keyword.get(opts, :recursion_desired, true), do: 1, else: 0

    question = DNS.Message.Question.new(name, type, :in)

    request_binary =
      DNS.Message.new()
      |> DNS.Message.add_question(question)
      |> DNS.Message.update_header_attr(:rd, rd)
      |> DNS.to_iodata()
      |> IO.iodata_to_binary()

    {request_binary, port, timeout, build_client_opts(opts)}
  end

  # Build Abyss.Client options from query options
  defp build_client_opts(opts) do
    client_opts = []

    client_opts =
      case Keyword.get(opts, :source) do
        nil -> client_opts
        source -> [{:source, source} | client_opts]
      end

    client_opts
  end

  # Parse DNS response binary
  defp parse_response(response_binary) do
    try do
      message = DNS.Message.from_iodata(response_binary)
      {:ok, message}
    rescue
      e -> {:error, {:parse_error, Exception.message(e)}}
    catch
      :throw, {reason, _details} when is_binary(reason) ->
        {:error, {:parse_error, reason}}

      :throw, reason ->
        {:error, {:parse_error, inspect(reason)}}
    end
  end
end
