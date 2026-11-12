defmodule YellowDog.Worker.ConnectionTest.FakeSocket do
  @moduledoc false
  # Stands in for YellowDog.Worker.Connection.Channel; every call runs in the
  # Connection process and is reported to the registered test process.

  def open(options) do
    socket = spawn_link(fn -> Process.sleep(:infinity) end)
    send(:connection_test, {:opened, socket, options, System.monotonic_time(:millisecond)})
    {:ok, socket}
  end

  def status(_socket), do: :connected

  def join(socket, topic, payload) do
    channel = spawn(fn -> Process.sleep(:infinity) end)
    send(:connection_test, {:joining, self(), socket, channel, topic, payload})

    receive do
      {:join_reply, :ok} -> {:ok, channel}
      {:join_reply, reply} -> reply
    after
      3_000 -> {:error, :timeout}
    end
  end

  def push(channel, event, payload) do
    send(:connection_test, {:pushed, channel, event, payload})
    :ok
  end

  def close(socket) do
    Process.unlink(socket)
    Process.exit(socket, :kill)
    :ok
  end
end

defmodule YellowDog.Worker.ConnectionTest do
  use ExUnit.Case, async: false
  import Bitwise
  alias YellowDog.ConfigSpec
  alias YellowDog.Worker.{Connection, ServiceManager}
  alias YellowDog.Worker.ConnectionTest.FakeSocket
  @moduletag :tmp_dir
  @token String.duplicate("a", 43)
  @tag_message YellowDog.Worker.Connection.Channel

  setup do
    Process.register(self(), :connection_test)
    :ok
  end

  test "derives the WebSocket URL and sends the token only in the join payload", ctx do
    manager = manager(ctx.tmp_dir)
    conn = connection(manager, management_url: "http://127.0.0.1:4270")
    assert_receive {:opened, _socket, options, _}, 3000
    assert options[:url] == "ws://127.0.0.1:4270/api/worker/connect"
    assert options[:params] == %{"worker_id" => "edge-01"}
    refute Keyword.has_key?(options, :headers)
    refute inspect(options) =~ @token
    {_channel, topic, payload} = join!()
    assert topic == "worker:edge-01"

    assert payload == %{
             "token" => @token,
             "report" => %{
               "worker_id" => "edge-01",
               "capabilities" => ["dns"],
               "services" => %{},
               "applied_revision" => nil,
               "applied_digest" => nil,
               "apply_error" => nil
             }
           }

    assert Connection.status(conn) == %{connected: true, connection_error: nil, apply_error: nil}
    refute inspect(:sys.get_state(conn)) =~ @token
    refute inspect(:sys.get_status(conn)) =~ @token
    :ok = stop_supervised(Connection)

    for file <- ~w(ca.pem client.pem client.key),
        do: File.write!(Path.join(ctx.tmp_dir, file), "")

    connection(manager,
      management_url: "https://management.example:8443",
      tls_ca_file: Path.join(ctx.tmp_dir, "ca.pem"),
      tls_cert_file: Path.join(ctx.tmp_dir, "client.pem"),
      tls_key_file: Path.join(ctx.tmp_dir, "client.key")
    )

    assert_receive {:opened, _socket, options, _}, 3000
    assert options[:url] == "wss://management.example:8443/api/worker/connect"
    assert options[:tls][:verify] == :verify_peer
    assert options[:tls][:cacertfile] == String.to_charlist(Path.join(ctx.tmp_dir, "ca.pem"))
    assert options[:tls][:certfile] == String.to_charlist(Path.join(ctx.tmp_dir, "client.pem"))
    assert options[:tls][:keyfile] == String.to_charlist(Path.join(ctx.tmp_dir, "client.key"))
  end

  test "a pushed target applies DNS and immediately reports the applied revision", ctx do
    manager = manager(ctx.tmp_dir)
    conn = connection(manager)
    {channel, _topic, _payload} = join!()
    assert ServiceManager.status(manager).origin == :awaiting_connection
    plan = dns_plan()
    deliver(conn, channel, target(plan))

    assert_receive {:pushed, ^channel, "report",
                    %{
                      "applied_revision" => 1,
                      "applied_digest" => digest,
                      "apply_error" => nil,
                      "capabilities" => ["dns"],
                      "services" => %{"dns-primary" => %{"state" => "running"}}
                    }},
                   3000

    assert {:ok, digest} == ConfigSpec.plan_digest(plan)
    assert ServiceManager.status(manager).ready
    port = get_in(plan, ["services", Access.at(0), "config", "port"])
    assert_dns(port)
    assert %{connected: true, apply_error: nil} = Connection.status(conn)

    stopped =
      plan
      |> Map.put("revision", 2)
      |> put_in(["services", Access.at(0), "desired_state"], "stopped")

    deliver(conn, channel, target(stopped))

    assert_receive {:pushed, ^channel, "report",
                    %{
                      "applied_revision" => 2,
                      "services" => %{"dns-primary" => %{"state" => "stopped"}}
                    }},
                   3000

    assert {:error, :econnrefused} =
             :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 1000)

    :ok = stop_supervised(Connection)
    :ok = stop_supervised(ServiceManager)
    restored = manager(ctx.tmp_dir)
    assert ServiceManager.status(restored).desired == stopped
    assert ServiceManager.status(restored).origin == :snapshot
  end

  test "stale, invalid and conflicting targets report apply errors without changing snapshots",
       ctx do
    manager = manager(ctx.tmp_dir)
    conn = connection(manager)
    {channel, _, _} = join!()
    plan = empty_plan(3)
    deliver(conn, channel, target(plan))
    assert_receive {:pushed, ^channel, "report", %{"applied_revision" => 3}}, 3000

    for {message, error} <- [
          {put_in(target(plan), ["target", "digest"], String.duplicate("0", 64)),
           "invalid_target"},
          {target(Map.put(plan, "worker_id", "other")), "invalid_target"},
          {%{"target" => "garbage"}, "invalid_target"},
          {target(empty_plan(2)), "stale_target"},
          {target(dns_plan() |> Map.put("revision", 3)), "invalid_target"}
        ] do
      deliver(conn, channel, message)

      assert_receive {:pushed, ^channel, "report",
                      %{"applied_revision" => 3, "apply_error" => ^error}},
                     3000

      assert %{connected: true, apply_error: ^error} = Connection.status(conn)
      assert ServiceManager.status(manager).desired == plan
    end

    higher = empty_plan(4)
    deliver(conn, channel, target(higher))

    assert_receive {:pushed, ^channel, "report",
                    %{"applied_revision" => 4, "apply_error" => nil}},
                   3000

    :ok = stop_supervised(Connection)
    :ok = stop_supervised(ServiceManager)
    recovered = manager(ctx.tmp_dir)
    restarted = connection(recovered)
    {channel, _, %{"report" => %{"applied_revision" => 4}}} = join!()
    deliver(restarted, channel, target(plan))

    assert_receive {:pushed, ^channel, "report",
                    %{"applied_revision" => 4, "apply_error" => "stale_target"}},
                   3000

    assert ServiceManager.status(recovered).desired == higher
  end

  test "reports are pushed as a periodic heartbeat while joined", ctx do
    connection(manager(ctx.tmp_dir), report_interval_ms: 100)
    {channel, _, _} = join!()
    assert_receive {:pushed, ^channel, "report", %{"worker_id" => "edge-01"}}, 1000
    assert_receive {:pushed, ^channel, "report", %{"worker_id" => "edge-01"}}, 1000
  end

  test "socket exit disconnects and reconnects after the default one second backoff", ctx do
    manager = manager(ctx.tmp_dir)
    conn = connection(manager)
    assert_receive {:opened, socket, _, _}, 3000
    join!()
    plan = empty_plan(1)
    assert %{connected: true} = Connection.status(conn)
    Process.exit(socket, :kill)
    assert %{connected: false, connection_error: "disconnected"} = disconnected(conn)
    refute_receive {:opened, _, _, _}, 800
    assert_receive {:opened, _, _, _}, 1000
    {channel, _, _} = join!()
    assert %{connected: true, connection_error: nil} = Connection.status(conn)
    deliver(conn, channel, target(plan))
    assert_receive {:pushed, ^channel, "report", %{"applied_revision" => 1}}, 3000
  end

  test "join rejections, server close and channel exit back off exponentially up to the cap",
       ctx do
    manager = manager(ctx.tmp_dir)
    conn = connection(manager, backoff_ms: {200, 800})
    assert_receive {:opened, _, _, t0}, 3000
    join!({:error, "unauthorized"})
    assert %{connected: false, connection_error: "unauthorized"} = Connection.status(conn)
    t1 = reopened_after(t0, 200)
    join!({:error, "unavailable"})
    assert %{connected: false, connection_error: "unavailable"} = Connection.status(conn)
    t2 = reopened_after(t1, 400)
    join!({:error, :timeout})
    assert %{connected: false, connection_error: "request_failed"} = Connection.status(conn)
    t3 = reopened_after(t2, 800)
    join!({:error, "unauthorized"})
    t4 = reopened_after(t3, 800)

    # A successful join resets the backoff; a server phx_close reconnects.
    {channel, _, _} = join!()
    assert %{connected: true, connection_error: nil} = Connection.status(conn)
    send(conn, {@tag_message, channel, "phx_close", %{}})
    assert %{connected: false, connection_error: "disconnected"} = Connection.status(conn)
    t5 = reopened_after(t4, 200)

    {channel, _, _} = join!()
    Process.exit(channel, :kill)
    assert_receive {:opened, _, _, t6}, 1000
    assert t6 - t5 >= 200
    refute inspect(:sys.get_state(conn)) =~ @token
  end

  test "URL-only initialization joins with and reuses the private persisted credential", ctx do
    path = Path.join(ctx.tmp_dir, "bootstrap.toml")

    File.write!(
      path,
      "management_url = \"http://127.0.0.1:4270\"\ndata_dir = #{inspect(Path.join(ctx.tmp_dir, "state"))}\n"
    )

    {:ok, bootstrap} = YellowDog.Worker.Bootstrap.load(path)
    options = Keyword.put(bootstrap, :connection_bootstrap, path) |> Keyword.delete(:connection)
    manager = start_supervised!({ServiceManager, options})
    {:ok, auth} = ServiceManager.connection_credentials(manager)

    client =
      start_supervised!(
        {Connection, bootstrap_path: path, manager: manager, socket_impl: FakeSocket}
      )

    assert_receive {:opened, _, opened, _}, 3000
    assert opened[:params] == %{"worker_id" => auth.worker_id}
    {_, topic, payload} = join!()
    assert topic == "worker:" <> auth.worker_id
    assert payload["token"] == auth.token
    assert payload["report"]["worker_id"] == auth.worker_id
    refute inspect(:sys.get_status(manager)) =~ auth.token
    refute inspect(ServiceManager.status(manager)) =~ auth.token
    refute inspect(:sys.get_status(client)) =~ auth.token
    refute inspect(:sys.get_state(client)) =~ auth.token
    :ok = stop_supervised(Connection)
    :ok = stop_supervised(ServiceManager)
    manager = start_supervised!({ServiceManager, options})
    assert {:ok, ^auth} = ServiceManager.connection_credentials(manager)

    start_supervised!(
      {Connection, bootstrap_path: path, manager: manager, socket_impl: FakeSocket}
    )

    {_, _, %{"token" => token}} = join!()
    assert token == auth.token
    assert ServiceManager.status(manager).origin == :awaiting_connection
  end

  test "real WebSocket client exchanges Phoenix frames and reconnects after close", ctx do
    {url, _listener} = ws_server(:gen_tcp, [])
    manager = manager(ctx.tmp_dir)

    conn =
      start_supervised!(
        {Connection, worker_id: "edge-01", manager: manager, management_url: url, token: @token}
      )

    assert_receive {:upgrade, request}, 5000
    assert request =~ "GET /api/worker/connect?vsn=2.0.0&worker_id=edge-01 HTTP/1.1\r\n"
    refute request =~ @token
    refute request =~ ~r/x-yellow-dog/i
    assert_receive {:ws, :gen_tcp, socket}, 3000
    [join_ref, ref, topic, "phx_join", payload] = recv_frame(:gen_tcp, socket)
    assert topic == "worker:edge-01"
    assert %{"token" => @token, "report" => %{"worker_id" => "edge-01"}} = payload
    send_frame(:gen_tcp, socket, [join_ref, ref, topic, "phx_reply", ok_reply()])
    plan = dns_plan()
    send_frame(:gen_tcp, socket, [join_ref, nil, topic, "target", target(plan)])

    assert [^join_ref, _, ^topic, "report", %{"applied_revision" => 1, "apply_error" => nil}] =
             recv_frame(:gen_tcp, socket)

    assert_dns(get_in(plan, ["services", Access.at(0), "config", "port"]))
    assert %{connected: true} = Connection.status(conn)

    # Oversized inbound messages are refused instead of buffered.
    send_frame(:gen_tcp, socket, [
      join_ref,
      nil,
      topic,
      "target",
      String.duplicate("a", 1_048_577)
    ])

    assert {8, <<1009::16, _::binary>>} = read_frame(:gen_tcp, socket)
    :gen_tcp.close(socket)
    assert_receive {:upgrade, _}, 5000
    assert %{connected: false} = Connection.status(conn)
    assert_receive {:ws, :gen_tcp, socket}, 3000

    [join_ref, ref, topic, "phx_join", %{"report" => %{"applied_revision" => 1}}] =
      recv_frame(:gen_tcp, socket)

    send_frame(:gen_tcp, socket, [
      join_ref,
      ref,
      topic,
      "phx_reply",
      %{"status" => "error", "response" => %{"code" => "unauthorized"}}
    ])

    assert_receive {:upgrade, _}, 5000
    assert %{connected: false, connection_error: "unauthorized"} = Connection.status(conn)
    assert_receive {:ws, :gen_tcp, socket}, 3000
    [join_ref, ref, topic, "phx_join", _] = recv_frame(:gen_tcp, socket)
    send_frame(:gen_tcp, socket, [join_ref, ref, topic, "phx_reply", ok_reply()])
    send_frame(:gen_tcp, socket, [join_ref, nil, topic, "target", %{"target" => nil}])
    assert [_, _, ^topic, "report", _] = recv_frame(:gen_tcp, socket)
    assert %{connected: true, connection_error: nil} = Connection.status(conn)
    :gen_tcp.close(socket)
    assert_receive {:upgrade, _}, 5000
    assert_dns(get_in(plan, ["services", Access.at(0), "config", "port"]))
  end

  test "WSS requires a trusted CA and presents optional mutual TLS credentials", ctx do
    {ca, cert, key} = certificates(ctx.tmp_dir)

    tls = [
      certfile: String.to_charlist(cert),
      keyfile: String.to_charlist(key),
      cacertfile: String.to_charlist(ca),
      verify: :verify_peer,
      fail_if_no_peer_cert: true
    ]

    {url, _listener} = ws_server(:ssl, tls)
    url = String.replace(url, "http://", "https://")
    manager = manager(ctx.tmp_dir)

    for extra <- [[], [tls_ca_file: ca]] do
      start_supervised!(
        {Connection,
         [worker_id: "edge-01", manager: manager, management_url: url, token: @token] ++ extra}
      )

      assert_receive {:tls_failed, _}, 5000
      refute_receive {:upgrade, _}, 300
      :ok = stop_supervised(Connection)
    end

    start_supervised!(
      {Connection,
       worker_id: "edge-01",
       manager: manager,
       management_url: url,
       token: @token,
       tls_ca_file: ca,
       tls_cert_file: cert,
       tls_key_file: key}
    )

    assert_receive {:upgrade, request}, 5000
    assert request =~ "GET /api/worker/connect?vsn=2.0.0&worker_id=edge-01 HTTP/1.1\r\n"
    assert_receive {:ws, :ssl, socket}, 3000
    assert [_, _, "worker:edge-01", "phx_join", %{"token" => @token}] = recv_frame(:ssl, socket)
  end

  defp disconnected(conn, attempts \\ 50) do
    case Connection.status(conn) do
      %{connected: true} when attempts > 0 ->
        Process.sleep(20)
        disconnected(conn, attempts - 1)

      status ->
        status
    end
  end

  defp reopened_after(previous, minimum) do
    assert_receive {:opened, _, _, at}, minimum + 1000
    assert at - previous >= minimum
    assert at - previous < minimum + 700
    at
  end

  defp join!(reply \\ :ok) do
    assert_receive {:joining, conn, _socket, channel, topic, payload}, 3000
    send(conn, {:join_reply, reply})
    {channel, topic, payload}
  end

  defp deliver(conn, channel, payload), do: send(conn, {@tag_message, channel, "target", payload})

  defp ok_reply, do: %{"status" => "ok", "response" => %{}}

  defp manager(dir),
    do: start_supervised!({ServiceManager, worker_id: "edge-01", data_dir: dir, source: nil})

  defp connection(manager, extra \\ []),
    do:
      start_supervised!(
        {Connection,
         Keyword.merge(
           [
             worker_id: "edge-01",
             manager: manager,
             management_url: "http://127.0.0.1:4270",
             token: @token,
             socket_impl: FakeSocket
           ],
           extra
         )}
      )

  defp empty_plan(revision),
    do: %{
      "schema_version" => 1,
      "worker_id" => "edge-01",
      "revision" => revision,
      "services" => [],
      "resources" => []
    }

  defp dns_plan do
    {:ok, plan} =
      ConfigSpec.decode(File.read!("../yellow_dog_config_spec/test/fixtures/complete_zone.toml"))

    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_, port}} = :inet.sockname(listener)
    :gen_tcp.close(listener)

    plan
    |> put_in(["services", Access.at(0), "config", "port"], port)
    |> put_in(["services", Access.at(0), "config", "allow_query"], ["127.0.0.0/8"])
  end

  defp target(plan) do
    {:ok, digest} = ConfigSpec.plan_digest(plan)
    %{"target" => %{"revision" => plan["revision"], "digest" => digest, "plan" => plan}}
  end

  defp assert_dns(port) do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 1000)
    query = <<1::16, 0::16, 1::16, 0::48, 3, "ns1", 7, "example", 3, "com", 0, 1::16, 1::16>>
    :ok = :gen_tcp.send(socket, <<byte_size(query)::16, query::binary>>)
    assert {:ok, response} = :gen_tcp.recv(socket, 0, 1000)
    assert response =~ <<192, 0, 2, 53>>
    :gen_tcp.close(socket)
  end

  # Minimal WebSocket endpoint: performs the upgrade, then hands the socket to
  # the test process, which reads masked client frames and writes server frames.
  defp ws_server(transport, tls) do
    listen = if transport == :ssl, do: tls, else: []

    {:ok, listener} =
      transport.listen(
        0,
        [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}] ++ listen
      )

    {:ok, {_, port}} =
      if transport == :ssl, do: :ssl.sockname(listener), else: :inet.sockname(listener)

    parent = self()
    acceptor = spawn_link(fn -> ws_accept_loop(transport, listener, parent) end)

    on_exit(fn ->
      transport.close(listener)
      if Process.alive?(acceptor), do: Process.exit(acceptor, :normal)
    end)

    {"http://127.0.0.1:#{port}", listener}
  end

  defp ws_accept_loop(transport, listener, parent) do
    accepted =
      if transport == :ssl do
        with {:ok, socket} <- :ssl.transport_accept(listener) do
          case :ssl.handshake(socket, 3000) do
            {:ok, socket} ->
              {:ok, socket}

            {:error, reason} ->
              send(parent, {:tls_failed, reason})
              :ssl.close(socket)
              :retry
          end
        end
      else
        :gen_tcp.accept(listener)
      end

    case accepted do
      {:ok, socket} ->
        request = read_head(transport, socket, "")
        send(parent, {:upgrade, request})
        [_, key] = Regex.run(~r/sec-websocket-key:\s*(\S+)/i, request)
        accept = Base.encode64(:crypto.hash(:sha, key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))

        :ok =
          transport.send(
            socket,
            "HTTP/1.1 101 Switching Protocols\r\nupgrade: websocket\r\nconnection: Upgrade\r\nsec-websocket-accept: #{accept}\r\n\r\n"
          )

        :ok = transport.controlling_process(socket, parent)
        send(parent, {:ws, transport, socket})
        ws_accept_loop(transport, listener, parent)

      :retry ->
        ws_accept_loop(transport, listener, parent)

      {:error, _} ->
        :ok
    end
  end

  defp read_head(transport, socket, bytes) do
    if String.contains?(bytes, "\r\n\r\n") do
      bytes
    else
      {:ok, next} = transport.recv(socket, 0, 3000)
      read_head(transport, socket, bytes <> next)
    end
  end

  defp recv_frame(transport, socket) do
    {1, data} = read_frame(transport, socket)
    Jason.decode!(data)
  end

  defp read_frame(transport, socket) do
    {:ok, <<_fin::4, opcode::4, 1::1, size::7>>} = transport.recv(socket, 2, 3000)

    size =
      case size do
        126 -> with {:ok, <<value::16>>} <- transport.recv(socket, 2, 3000), do: value
        127 -> with {:ok, <<value::64>>} <- transport.recv(socket, 8, 3000), do: value
        value -> value
      end

    {:ok, mask} = transport.recv(socket, 4, 3000)
    {:ok, data} = if size == 0, do: {:ok, ""}, else: transport.recv(socket, size, 3000)

    data =
      data
      |> :binary.bin_to_list()
      |> Enum.with_index()
      |> Enum.map(fn {byte, index} -> bxor(byte, :binary.at(mask, rem(index, 4))) end)
      |> :binary.list_to_bin()

    {opcode, data}
  end

  defp send_frame(transport, socket, message) do
    data = Jason.encode!(message)
    size = byte_size(data)

    header =
      cond do
        size < 126 -> <<0x81, size>>
        size < 65_536 -> <<0x81, 126, size::16>>
        true -> <<0x81, 127, size::64>>
      end

    :ok = transport.send(socket, [header, data])
  end

  defp certificates(dir) do
    cert = Path.join(dir, "tls.pem")
    key = Path.join(dir, "tls.key")
    ca = Path.join(dir, "ca.pem")
    ca_key = Path.join(dir, "ca.key")
    csr = Path.join(dir, "tls.csr")

    for arguments <- [
          ~w(req -x509 -newkey rsa:2048 -nodes -keyout #{ca_key} -out #{ca} -days 1 -subj) ++
            ["/CN=Worker Test CA"],
          ~w(req -newkey rsa:2048 -nodes -keyout #{key} -out #{csr} -subj /CN=127.0.0.1 -addext subjectAltName=IP:127.0.0.1),
          ~w(x509 -req -in #{csr} -CA #{ca} -CAkey #{ca_key} -CAcreateserial -out #{cert} -days 1 -copy_extensions copy)
        ] do
      {_, 0} = System.cmd("openssl", arguments, stderr_to_stdout: true)
    end

    {ca, cert, key}
  end
end
