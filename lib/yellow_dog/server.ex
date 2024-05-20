defmodule YellowDog.Server do
  @moduledoc """
  Heart of the DNS server.

  uses directly the Erlang libraries
  - [gen_udp](https://www.erlang.org/doc/man/gen_udp.html)
  - [gen_tcp](https://www.erlang.org/doc/man/gen_tcp.html)

  """

  # https://hexdocs.pm/logger/
  require Logger

  import YellowDog.Utils
  import YellowDog.Config

  # alias YellowDog.DNS.Message.EdnsCode
  # alias YellowDog.DNS.Message.RCode
  # alias YellowDog.DNS.ResourceRecord.Type

  # alias YellowDog.DNS.Message.Record, as: MRecord

  # Milli-seconds
  @timeout 2000
  # Should be enough for DNS over UDP
  @read_length 4096

  # Milli-seconds
  @stats_delay 600_000

  # RFC 8467, section 4.1
  # @pad_block_size 468

  # @minimum_ttl 0

  @spec start() :: no_return
  def start() do
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

    version =
      if config("ipv4-only") do
        :inet
      else
        :inet6
        # Depending on the OS parameters (sysctl net.ipv6.bindv6only on
        # Linux), it allows us to listen on IPv6 *and* IPv4.
      end

    addresses =
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

    _udp_servers =
      Enum.map(addresses, fn address ->
        Logger.info("Starting UDP server for #{a2s(address)}")
        options = [version, :binary, {:ip, address}, active: false]

        options =
          if config("ipv6-only") do
            # Warning: if you do NOT want
            options ++ [ipv6_v6only: true]
            # the ipv6_v6only option, do
            # not use it, even with value
            # "false".
          else
            options
          end

        socket_result =
          :gen_udp.open(config("port"), options)

        socket = socket_open(socket_result)
        udp_pid = spawn_link(YellowDog.Server, :udp_loop_acceptor, [socket, config("bases")])
        Process.monitor(udp_pid)
      end)

    _tcp_servers =
      Enum.map(addresses, fn address ->
        Logger.info("Starting TCP server for #{a2s(address)}")

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

    _tls_servers =
      if config("dot") do
        Enum.map(addresses, fn address ->
          Logger.info("Starting DoT server for #{a2s(address)}")

          options = [
            version,
            :binary,
            {:ip, address},
            active: false,
            packet: 2,
            certfile: config("dot-cert"),
            keyfile: config("dot-key")
          ]

          # advertised_protocols: ["dot"]])
          options =
            if config("ipv6-only") do
              options ++ [ipv6_v6only: true]
            else
              options
            end

          socket_result = :ssl.listen(config("dot-port"), options)
          socket = socket_open(socket_result, config("dot-port"))
          tls_pid = spawn_link(YellowDog.Server, :tls_loop_acceptor, [socket, config("bases")])
          Process.monitor(tls_pid)
        end)
      else
        []
      end

    # Logger.notice appeared only with Elixir 1.11
    Logger.warn("Receiving requests on port #{config("port")}")
    stats_pid = spawn_link(YellowDog.Server, :stats_print, [])
    Process.register(stats_pid, YellowDog.Stats)
    # Block here forever while the servers (UDP and TCP) run
    receive do
      {:DOWN, ref, type, proc, reason} ->
        Logger.error(
          "DNS server #{inspect(type)} #{inspect(proc)} (#{inspect(ref)}) ended, but it should never happen: #{inspect(reason)}"
        )
    end
  end

  def stats() do
    # https://www.erlang.org/doc/man/erlang.html#system_info-1 https://www.erlang.org/doc/man/erlang#memory-1
    "[VM resources] Processes: #{:erlang.system_info(:process_count)}/#{:erlang.system_info(:process_limit)} Ports: #{:erlang.system_info(:port_count)}/#{:erlang.system_info(:port_limit)} Atoms: #{:erlang.system_info(:atom_count)}/#{:erlang.system_info(:atom_limit)} Memory: #{:erlang.memory(:total)} bytes"
  end

  def stats_print() do
    Logger.info(stats())
    :timer.sleep(@stats_delay)
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

  @spec tls_loop_acceptor(integer, charlist) :: no_return
  def tls_loop_acceptor(socket, bases) do
    result = :ssl.transport_accept(socket)

    case result do
      {:ok, client} ->
        accepted = :ssl.handshake(client)

        case accepted do
          {:ok, client_socket} ->
            remote_client = :ssl.peername(client)

            case remote_client do
              {:ok, {client, port}} ->
                Logger.debug("Starting a new TCP session with #{inspect(a2s(client))}")

                spawn(YellowDog.Server, :tls_request_acceptor, [
                  client_socket,
                  bases,
                  client,
                  port
                ])

              {:error, reason} ->
                Logger.error("Cannot find remote client info: #{inspect(reason)}")
            end

          {:error, reason} ->
            Logger.error("Cannot handshake TLS session #{inspect(reason)}")
        end

      {:error, :system_limit} ->
        Logger.error("Accept error TLS: a limit was reached.")
        # https://www.erlang.org/doc/efficiency_guide/advanced.html#system-limits
        Logger.error(stats())

      {:error, reason} ->
        Logger.error("Accept error on TLS socket #{inspect(socket)}: #{inspect(reason)}")
    end

    tls_loop_acceptor(socket, bases)
  end

  def tcp_request_acceptor(socket, bases, client, port) do
    result = :gen_tcp.recv(socket, 0, @timeout)

    case result do
      # No data yet
      {:ok, nil} ->
        tcp_request_acceptor(socket, bases, client, port)

      {:ok, request} ->
        # We
        spawn(YellowDog.Server, :serve, [:tcp, socket, bases, client, port, request])
        # spawn a new process for each request, so, we may send
        # responses out-of-order (no problem, RFC 7766, section 7).
        # Wait on the
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

  def tls_request_acceptor(socket, bases, client, port) do
    result = :ssl.recv(socket, 0, @timeout)

    case result do
      # No data yet
      {:ok, nil} ->
        tls_request_acceptor(socket, bases, client, port)

      {:ok, request} ->
        spawn(YellowDog.Server, :serve, [:tls, socket, bases, client, port, request])
        tls_request_acceptor(socket, bases, client, port)

      # Nothing to do
      {:error, :closed} ->
        Logger.debug("Normal end of TLS #{inspect(socket)}")

      {:error, :timeout} ->
        Logger.error("Timeout on TLS socket #{inspect(socket)} from client #{a2s(client)}")
        :ssl.shutdown(socket, :read_write)

      {:error, :enotconn} ->
        Logger.debug("End of TLS #{inspect(socket)}")
        :ssl.shutdown(socket, :read_write)

      _ ->
        Logger.error(
          "Unexpected read on TLS socket #{inspect(socket)} from client #{a2s(client)}: #{inspect(result)}"
        )
    end
  end

  def serve(protocol, socket, bases, client, port, data) do
    Logger.debug("Serving #{a2s(client)}")

    if config("statistics") do
      YellowDog.Statistics.post(:protocols, protocol)
    end

    YellowDog.DNS.Message.from_buffer(data)
    |> make_response(protocol, bases, client, port)
    |> write(protocol, socket, client, port)
  end

  def make_response(%YellowDog.DNS.Message{} = message, protocol, bases, client, port) do
    message = message |> YellowDog.DNS.Message.update_header_attr(:qr, 1)
    {:ok, message}
  end

  @spec write(
          {:ok, any},
          :udp | :tcp | :tls,
          integer,
          YellowDog.Utils.address(),
          integer | {:error, any}
        ) ::
          :ok | {:error, any}
  def write({:ok, data}, :udp, socket, client, port) do
    Logger.debug("Sending answer to #{a2s(client)}")
    :gen_udp.send(socket, client, port, data)
  end

  def write({:ok, data}, :tls, socket, client, _port) do
    length = byte_size(data)
    Logger.debug("Sending answer of #{length} bytes to #{a2s(client)}")
    :ssl.send(socket, data)
  end

  def write({:ok, data}, :tcp, socket, client, _port) do
    length = byte_size(data)
    Logger.debug("Sending answer of #{length} bytes to #{a2s(client)}")
    :gen_tcp.send(socket, data)
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

  @spec gen_cookie(YellowDog.Utils.address(), binary) :: binary
  def gen_cookie(client_address, client_cookie) do
    # RFC 7873, section 4.2.
    one_byte = tuple_size(client_address) == 4

    addr =
      Enum.reduce(Tuple.to_list(client_address), [], fn d, acc ->
        if one_byte do
          acc ++ [d]
        else
          if d >= 256 do
            high = trunc(d / 256)
            acc ++ [high, d - high * 256]
          else
            acc ++ [0, d]
          end
        end
      end)

    Binary.part(
      :crypto.hash(
        :sha256,
        config("secret-salt-for-cookies") <> Binary.from_list(addr) <> client_cookie
      ),
      0,
      8
    )
  end

  @spec legit_cookie(YellowDog.Utils.address(), binary, nil | binary) :: boolean
  def legit_cookie(client_address, client_cookie, server_cookie) do
    server_cookie == gen_cookie(client_address, client_cookie)
  end
end
