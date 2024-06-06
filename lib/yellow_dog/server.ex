defmodule YellowDog.Server do
  @moduledoc """
  Start a GenServer to YellowDog DNS Server.

  uses directly the Erlang libraries
  - [gen_udp](https://www.erlang.org/doc/man/gen_udp.html)
  - [gen_tcp](https://www.erlang.org/doc/man/gen_tcp.html)

  """

  use GenServer

  require Logger

  import YellowDog.Utils

  alias YellowDog.DNS.Message
  alias YellowDog.DNS.Message.EDNS0
  alias YellowDog.DNS.Message.RCode
  alias YellowDog.DNS.ResourceRecord.Type, as: RType
  alias YellowDog.DNS.Class, as: QClass

  # alias YellowDog.DNS.Message.Record, as: MRecord

  # Milli-seconds
  @timeout 2000
  # rfc 1035
  @udp_max_size 1232
  # Should be enough for DNS over UDP
  @read_length 4096

  # Milli-seconds
  @stats_interval 60_000

  # RFC 8467, section 4.1
  # @pad_block_size 468

  # @minimum_ttl 0

  def config() do
    YellowDog.Config.config("server")
  end

  def config(name) do
    config() |> Map.get(name)
  end

  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  @impl true
  def init(_) do
    state = %{}
    {:ok, state, {:continue, :start_listening}}
  end

  @impl true
  def handle_continue(:start_listening, state) do
    config_logger()

    state =
      state
      |> setup_addresses()
      |> start_listening()

    {:noreply, state}
  end

  def config_logger() do
    Logger.configure(level: config("log-level"))
    Logger.add_backend({LoggerSyslogBackend, :default_logger})

    Logger.configure_backend({LoggerSyslogBackend, :default_logger},
      facility: config("log-facility"),
      app_id: "YellowDog",
      format: "[$level] $metadata $message",
      metadata: [:all]
    )

    if not config("console") do
      Logger.remove_backend(Logger.Backends.Console)
    end
  end

  def setup_addresses(state) do
    state =
      state
      |> Map.put(
        :version,
        if config("ipv4-only") do
          :inet
        else
          :inet6
          # Depending on the OS parameters (sysctl net.ipv6.bindv6only on
          # Linux), it allows us to listen on IPv6 *and* IPv4.
        end
      )

    state =
      state
      |> Map.put(
        :addresses,
        case config("bind") do
          [:any] ->
            [:any]

          l ->
            Enum.filter(
              l,
              fn address ->
                (config("ipv4-only") and address_family(address) == :inet4) or
                  (config("ipv6-only") and address_family(address) == :inet6) or
                  (not config("ipv4-only") and not config("ipv6-only"))
              end
            )
        end
      )

    state
  end

  def start_listening(state) do
    version = Map.get(state, :version)
    addresses = Map.get(state, :addresses)

    udp_servers =
      Enum.map(addresses, fn address ->
        Logger.info("Starting UDP server for #{a2s(address)}##{config("port")}")
        options = [version, :binary, {:ip, address}, active: false]

        options =
          if config("ipv6-only") do
            options ++ [ipv6_v6only: true]
          else
            options
          end

        socket_result =
          :gen_udp.open(config("port"), options)

        socket = socket_open(socket_result)
        udp_pid = spawn_link(YellowDog.Server, :udp_loop_acceptor, [socket, config("bases")])
        Process.monitor(udp_pid)
      end)

    state = state |> Map.put(:udp_servers, udp_servers)

    tcp_servers =
      Enum.map(addresses, fn address ->
        Logger.info("Starting TCP server for #{a2s(address)}##{config("port")}")

        options = [
          version,
          :binary,
          {:ip, address},
          active: false,
          # Automatically add/read a 2-bytes
          packet: 2
        ]

        # length before data. See
        # https://www.erlang.org/doc/man/inet.html#setopts-2
        options =
          if config("ipv6-only") do
            options ++ [ipv6_v6only: true]
          else
            options
          end

        socket_result = :gen_tcp.listen(config("port"), options)
        socket = socket_open(socket_result)
        tcp_pid = spawn_link(YellowDog.Server, :tcp_loop_acceptor, [socket, config("bases")])
        Process.monitor(tcp_pid)
      end)

    state = state |> Map.put(:tcp_servers, tcp_servers)

    state
  end

  def stats() do
    # https://www.erlang.org/doc/man/erlang.html#system_info-1
    # https://www.erlang.org/doc/man/erlang#memory-1
    "[VM resources]" <>
      " Processes: #{:erlang.system_info(:process_count)}/#{:erlang.system_info(:process_limit)}" <>
      " Ports: #{:erlang.system_info(:port_count)}/#{:erlang.system_info(:port_limit)}" <>
      " Atoms: #{:erlang.system_info(:atom_count)}/#{:erlang.system_info(:atom_limit)}" <>
      " Memory: #{:erlang.memory(:total)} bytes"
  end

  def stats_print() do
    Logger.info(stats())
    :timer.sleep(@stats_interval)
    stats_print()
  end

  def socket_open(result, port \\ config("port")) do
    case result do
      {:ok, socket} ->
        socket

      {:error, :eacces} ->
        Logger.error("Cannot bind to port #{port}: permission denied")
        exit("Permission denied")

      {:error, :eaddrinuse} ->
        Logger.error("Cannot bind to port #{port}: already in use")
        exit("Port already in use")

      {:error, reason} ->
        Logger.error("Cannot bind to port #{port}: #{inspect(reason)}")
        exit("Generic error")
    end
  end

  @spec udp_loop_acceptor(integer, charlist) :: no_return
  def udp_loop_acceptor(socket, bases) do
    read = :gen_udp.recv(socket, @read_length)

    case read do
      {:ok, {client, port, request}} ->
        spawn(YellowDog.Server, :serve, [:udp, socket, bases, client, port, request])

      {:error, reason} ->
        Logger.error("Read error on UDP socket #{inspect(socket)}: #{inspect(reason)}")
    end

    udp_loop_acceptor(socket, bases)
  end

  @spec tcp_loop_acceptor(integer, charlist) :: no_return
  def tcp_loop_acceptor(socket, bases) do
    accepted = :gen_tcp.accept(socket)

    case accepted do
      {:ok, client_socket} ->
        remote_client = :inet.peername(client_socket)

        case remote_client do
          {:ok, {client, port}} ->
            Logger.debug("Starting a new TCP session with #{a2s(client)}")
            spawn(YellowDog.Server, :tcp_request_acceptor, [client_socket, bases, client, port])

          {:error, reason} ->
            Logger.error("Cannot find remote client info: #{inspect(reason)}")
        end

      {:error, :system_limit} ->
        Logger.error("Accept error TCP: a limit was reached.")
        # https://www.erlang.org/doc/efficiency_guide/advanced.html#system-limits
        Logger.error(stats())

      {:error, reason} ->
        Logger.error("Accept error on TCP socket #{inspect(socket)}: #{inspect(reason)}")
    end

    tcp_loop_acceptor(socket, bases)
  end

  def tcp_request_acceptor(socket, bases, client, port) do
    result = :gen_tcp.recv(socket, 0, @timeout)

    case result do
      # No data yet
      {:ok, nil} ->
        tcp_request_acceptor(socket, bases, client, port)

      {:ok, request} ->
        spawn(YellowDog.Server, :serve, [:tcp, socket, bases, client, port, request])
        tcp_request_acceptor(socket, bases, client, port)

      # same TCP connection, to reuse it (you can test with dig's
      # +keepopen option).
      # Nothing to do
      {:error, :closed} ->
        Logger.debug("Normal end of TCP #{inspect(socket)}")
        Port.close(socket)

      {:error, :timeout} ->
        Logger.error("Timeout on TCP socket #{inspect(socket)} from client #{a2s(client)}")
        :gen_tcp.shutdown(socket, :read_write)
        Port.close(socket)

      {:error, :enotconn} ->
        Logger.debug("End of TCP #{inspect(socket)}")
        # Probably useless since, if we are here, it means the socket is closed.
        :gen_tcp.shutdown(socket, :read_write)
        # Reclaiming the Erlang (not TCP) port is important, otherwise we'll run in a
        Port.close(socket)

      # :system_limit problem (see issue #35).
      _ ->
        Logger.error(
          "Unexpected read on TCP socket #{inspect(socket)} from client #{a2s(client)}: #{inspect(result)}"
        )
    end
  end

  def serve(protocol, socket, bases, client, port, data) do
    Logger.debug("Serving #{a2s(client)}")

    if config("telemetry") do
      # YellowDog.Telemetry.post(:protocols, protocol)
    end

    case data do
      data when is_bitstring(data) ->
        Logger.debug("incomming message: #{inspect(data, limit: :infinity)}")

        YellowDog.DNS.Message.from_buffer(<<data::binary>>)
        |> log_query(protocol, bases, client, port)
        |> make_response(protocol, bases, client, port)
        |> write(protocol, socket, client, port)

      data ->
        Logger.warning("Unexpected data #{inspect(data)} from #{a2s(client)}")
    end
  end

  def log_query(%YellowDog.DNS.Message{} = message, protocol, _bases, client, port) do
    message.qdlist
    |> Enum.each(fn qn ->
      Logger.info(
        "Query in #{protocol} from #{a2s(client)}##{port} #{qn.name} #{RType.get_name(qn.type)} #{QClass.get_name(qn.class)}"
      )
    end)

    message
  end

  def make_response(%Message{} = message, protocol, _bases, client, port) do
    Logger.debug(Message.to_print(message))

    YellowDog.Forwarder.resolve(message, protocol, client, port)
  end

  @spec write(
          {:ok, any},
          :udp | :tcp,
          integer,
          YellowDog.Utils.address(),
          integer | {:error, any}
        ) ::
          :ok | {:error, any}
  def write({:ok, data}, :udp, socket, client, port) do
    Logger.debug("Sending answer to #{a2s(client)}")
    :gen_udp.send(socket, client, port, data)
  end

  def write({:ok, data}, :tcp, socket, client, _port) do
    length = byte_size(data)
    Logger.debug("Sending answer of #{length} bytes to #{a2s(client)}")
    :gen_tcp.send(socket, <<length::16, data::binary>>)
  end

  def write({:problem, reason, data}, :udp, socket, client, port) do
    Logger.info("Replying FORMERR to #{a2s(client)} because #{reason}")
    :gen_udp.send(socket, client, port, data)
  end

  def write({:problem, reason, data}, :tcp, socket, client, _port) do
    Logger.info("Replying FORMERR to #{a2s(client)} because #{reason}")
    :gen_tcp.send(socket, data)
  end

  def write({:error, reason}, _protocol, _socket, client, _port) do
    Logger.info("We ignore #{a2s(client)} because #{reason}")
  end

  def forward_to_google_dns(message) do
    forward_to(message, {8, 8, 8, 8}, 53)
  end

  def forward_to(message, addr, port \\ 53) do
    with {:ok, socket} <- :gen_tcp.connect(addr, port, active: false),
         buffer <- YellowDog.DNS.Message.to_buffer(message),
         :ok <- :gen_tcp.send(socket, <<byte_size(buffer)::16, buffer::binary>>),
         {:ok, [a, b]} <- :gen_tcp.recv(socket, 2),
         length <- Bitwise.<<<(a, 8) |> Bitwise.bor(b),
         {:ok, data} <- :gen_tcp.recv(socket, length),
         resp_msg <- for(byte <- data, into: <<>>, do: <<byte::8>>) do
      Logger.debug(
        "forwarder #{a2s(addr)}##{port} awnser #{inspect(resp_msg, limit: :infinity)} "
      )

      resp_msg
    else
      e ->
        Logger.error("serv_fail at forward to #{a2s(addr)}##{port} #{inspect(e)}")

        message
        |> YellowDog.DNS.Message.update_header_attr(:qr, 1)
        |> YellowDog.DNS.Message.update_header_attr(:rcode, RCode.serv_fail())
        |> YellowDog.DNS.Message.to_buffer()
    end
  end
end
