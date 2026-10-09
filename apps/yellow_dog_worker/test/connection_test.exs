defmodule YellowDog.Worker.ConnectionTest do
  use ExUnit.Case, async: false
  alias YellowDog.ConfigSpec
  alias YellowDog.Worker.{Connection, ConnectionHTTP, ServiceManager}
  @moduletag :tmp_dir
  @token String.duplicate("a", 43)

  test "URL-only initialization retries a lost response and restart with the same private credential",
       ctx do
    {url, replies} = server()
    path = Path.join(ctx.tmp_dir, "bootstrap.toml")

    File.write!(
      path,
      "management_url = #{inspect(url)}\ndata_dir = #{inspect(Path.join(ctx.tmp_dir, "state"))}\npoll_interval_ms = 15000\n"
    )

    {:ok, bootstrap} = YellowDog.Worker.Bootstrap.load(path)
    options = Keyword.put(bootstrap, :connection_bootstrap, path) |> Keyword.delete(:connection)
    manager = start_supervised!({ServiceManager, options})
    {:ok, auth} = ServiceManager.connection_credentials(manager)
    respond(replies, {0, %{}})
    client = start_supervised!({Connection, bootstrap_path: path, manager: manager})
    assert_receive {:request, headers, %{"worker_id" => id, "applied_revision" => nil}}, 3000
    assert id == auth.worker_id
    assert headers =~ "Bearer #{auth.token}"
    assert headers =~ "POST /api/worker/connect"
    assert %{connected: false} = Connection.status(client)
    respond(replies, %{"worker_id" => id, "target" => nil})
    assert %{connected: true} = Connection.poll(client)
    assert_receive {:request, retry_headers, %{"worker_id" => ^id}}, 3000
    assert retry_headers =~ "Bearer #{auth.token}"
    refute inspect(:sys.get_status(manager)) =~ auth.token
    refute inspect(ServiceManager.status(manager)) =~ auth.token
    refute inspect(:sys.get_status(client)) =~ auth.token
    :ok = stop_supervised(Connection)
    :ok = stop_supervised(ServiceManager)
    manager = start_supervised!({ServiceManager, options})
    assert {:ok, ^auth} = ServiceManager.connection_credentials(manager)
    start_supervised!({Connection, bootstrap_path: path, manager: manager})
    assert_receive {:request, restarted_headers, %{"worker_id" => ^id}}, 3000
    assert restarted_headers =~ "Bearer #{auth.token}"
    assert ServiceManager.status(manager).origin == :awaiting_connection
  end

  test "real HTTP polling applies DNS, reports observations and keeps runtime on disconnect",
       ctx do
    {url, replies} = server()
    manager = manager(ctx.tmp_dir)
    connection = connection(url, manager)
    assert_receive {:request, headers, %{"applied_revision" => nil}}, 3000
    assert headers =~ "Bearer #{@token}"
    assert ServiceManager.status(manager).origin == :awaiting_connection
    plan = dns_plan()
    respond(replies, target(plan))
    assert %{connected: true, apply_error: nil} = Connection.poll(connection)
    assert ServiceManager.status(manager).ready
    port = get_in(plan, ["services", Access.at(0), "config", "port"])
    assert_dns(port)
    assert %{connected: true} = Connection.poll(connection)

    assert_receive {:request, _,
                    %{
                      "applied_revision" => 1,
                      "capabilities" => ["dns"],
                      "services" => %{"dns-primary" => %{"state" => "running"}}
                    }},
                   3000

    respond(replies, {401, %{}})
    assert %{connected: false, connection_error: "unauthorized"} = Connection.poll(connection)
    assert_dns(port)
    respond(replies, {503, %{}})
    assert %{connected: false} = Connection.poll(connection)
    assert_dns(port)
    refute inspect(:sys.get_status(connection)) =~ @token

    stopped =
      plan
      |> Map.put("revision", 2)
      |> put_in(["services", Access.at(0), "desired_state"], "stopped")

    respond(replies, target(stopped))
    assert %{connected: true, apply_error: nil} = Connection.poll(connection)

    assert {:error, :econnrefused} =
             :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 1000)

    assert %{connected: true} = Connection.poll(connection)

    assert_receive {:request, _,
                    %{
                      "applied_revision" => 2,
                      "services" => %{"dns-primary" => %{"state" => "stopped"}}
                    }},
                   3000

    respond(replies, {401, %{}})
    :ok = stop_supervised(Connection)
    :ok = stop_supervised(ServiceManager)
    restored = manager(ctx.tmp_dir)
    assert ServiceManager.status(restored).desired == stopped
    assert ServiceManager.status(restored).origin == :snapshot

    assert {:error, :econnrefused} =
             :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 1000)
  end

  test "rejects invalid identity digest stale and conflicting targets without changing snapshots",
       ctx do
    {url, replies} = server()
    manager = manager(ctx.tmp_dir)
    client = connection(url, manager)
    plan = empty_plan(3)
    respond(replies, target(plan))
    assert %{apply_error: nil} = Connection.poll(client)

    for response <- [
          Map.put(target(plan), "worker_id", "another-worker"),
          put_in(target(plan), ["target", "digest"], String.duplicate("0", 64)),
          target(Map.put(plan, "worker_id", "other"))
        ] do
      respond(replies, response)
      Connection.poll(client)
      assert ServiceManager.status(manager).desired == plan
    end

    respond(replies, target(empty_plan(2)))
    assert %{apply_error: "stale_target"} = Connection.poll(client)
    different = dns_plan() |> Map.put("revision", 3)
    respond(replies, target(different))
    assert %{apply_error: "invalid_target"} = Connection.poll(client)
    assert ServiceManager.status(manager).desired == plan
    higher = empty_plan(4)
    respond(replies, target(higher))
    assert %{apply_error: nil} = Connection.poll(client)
    assert ServiceManager.status(manager).desired == higher
    :ok = stop_supervised(Connection)
    :ok = stop_supervised(ServiceManager)
    recovered = manager(ctx.tmp_dir)
    assert ServiceManager.status(recovered).desired == higher
    restarted = connection(url, recovered)
    respond(replies, target(plan))
    assert %{apply_error: "stale_target"} = Connection.poll(restarted)
    assert ServiceManager.status(recovered).desired == higher
  end

  test "HTTP redirects are refused and large streaming responses are bounded" do
    {url, replies} = server(true)
    options = [management_url: url, token: @token]
    respond(replies, {302, %{}})
    assert {:error, :request_failed} = ConnectionHTTP.connect(options, %{})
    respond(replies, {200, String.duplicate("a", 1_048_577)})
    assert {:error, :response_too_large} = ConnectionHTTP.connect(options, %{})
    respond(replies, {503, String.duplicate("a", 1_048_577)})
    assert {:error, :response_too_large} = ConnectionHTTP.connect(options, %{})
    respond(replies, {206, target(empty_plan(1))})
    assert {:error, :request_failed} = ConnectionHTTP.connect(options, %{})
  end

  test "HTTPS requires a trusted CA and presents optional mutual TLS credentials", ctx do
    cert = Path.join(ctx.tmp_dir, "tls.pem")
    key = Path.join(ctx.tmp_dir, "tls.key")
    ca = Path.join(ctx.tmp_dir, "ca.pem")
    ca_key = Path.join(ctx.tmp_dir, "ca.key")
    csr = Path.join(ctx.tmp_dir, "tls.csr")

    {_, 0} =
      System.cmd(
        "openssl",
        [
          "req",
          "-x509",
          "-newkey",
          "rsa:2048",
          "-nodes",
          "-keyout",
          ca_key,
          "-out",
          ca,
          "-days",
          "1",
          "-subj",
          "/CN=Worker Test CA"
        ],
        stderr_to_stdout: true
      )

    {_, 0} =
      System.cmd(
        "openssl",
        [
          "req",
          "-newkey",
          "rsa:2048",
          "-nodes",
          "-keyout",
          key,
          "-out",
          csr,
          "-subj",
          "/CN=127.0.0.1",
          "-addext",
          "subjectAltName=IP:127.0.0.1"
        ],
        stderr_to_stdout: true
      )

    {_, 0} =
      System.cmd(
        "openssl",
        [
          "x509",
          "-req",
          "-in",
          csr,
          "-CA",
          ca,
          "-CAkey",
          ca_key,
          "-CAcreateserial",
          "-out",
          cert,
          "-days",
          "1",
          "-copy_extensions",
          "copy"
        ],
        stderr_to_stdout: true
      )

    {:ok, listener} =
      :ssl.listen(0, [
        :binary,
        active: false,
        ip: {127, 0, 0, 1},
        certfile: String.to_charlist(cert),
        keyfile: String.to_charlist(key),
        cacertfile: String.to_charlist(ca),
        verify: :verify_peer,
        fail_if_no_peer_cert: true
      ])

    {:ok, {_, port}} = :ssl.sockname(listener)
    acceptor = spawn_link(fn -> tls_accept_loop(listener) end)

    on_exit(fn ->
      :ssl.close(listener)
      if Process.alive?(acceptor), do: Process.exit(acceptor, :normal)
    end)

    options = [management_url: "https://127.0.0.1:#{port}", token: @token]
    assert {:error, :request_failed} = ConnectionHTTP.connect(options, %{})
    assert {:error, :request_failed} = ConnectionHTTP.connect(options ++ [tls_ca_file: ca], %{})

    assert {:ok, %{"worker_id" => "edge-01", "target" => nil}} =
             ConnectionHTTP.connect(
               options ++ [tls_ca_file: ca, tls_cert_file: cert, tls_key_file: key],
               %{}
             )
  end

  defp tls_accept_loop(listener) do
    case :ssl.transport_accept(listener) do
      {:ok, socket} ->
        case :ssl.handshake(socket, 3000) do
          {:ok, socket} ->
            read_request(socket, "", :ssl)
            bytes = Jason.encode!(%{"worker_id" => "edge-01", "target" => nil})

            :ssl.send(socket, [
              "HTTP/1.1 200 OK\r\ncontent-length: #{byte_size(bytes)}\r\nconnection: close\r\n\r\n",
              bytes
            ])

            :ssl.close(socket)

          {:error, _} ->
            :ssl.close(socket)
        end

        tls_accept_loop(listener)

      {:error, :closed} ->
        :ok
    end
  end

  defp manager(dir),
    do: start_supervised!({ServiceManager, worker_id: "edge-01", data_dir: dir, source: nil})

  defp connection(url, manager),
    do:
      start_supervised!(
        {Connection,
         worker_id: "edge-01",
         manager: manager,
         management_url: url,
         token: @token,
         poll_interval_ms: 60_000}
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
    put_in(plan, ["services", Access.at(0), "config", "port"], port)
  end

  defp target(plan) do
    {:ok, digest} = ConfigSpec.plan_digest(plan)

    %{
      "worker_id" => "edge-01",
      "target" => %{"revision" => plan["revision"], "digest" => digest, "plan" => plan}
    }
  end

  defp assert_dns(port) do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 1000)
    query = <<1::16, 0::16, 1::16, 0::48, 3, "ns1", 7, "example", 3, "com", 0, 1::16, 1::16>>
    :ok = :gen_tcp.send(socket, <<byte_size(query)::16, query::binary>>)
    assert {:ok, response} = :gen_tcp.recv(socket, 0, 1000)
    assert response =~ <<192, 0, 2, 53>>
    :gen_tcp.close(socket)
  end

  defp respond(agent, response), do: Agent.update(agent, fn _ -> response end)

  defp server(chunked? \\ false) do
    replies = start_supervised!({Agent, fn -> %{"worker_id" => "edge-01", "target" => nil} end})

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_, port}} = :inet.sockname(listener)
    parent = self()
    acceptor = spawn_link(fn -> accept_loop(listener, replies, parent, chunked?) end)

    on_exit(fn ->
      :gen_tcp.close(listener)
      if Process.alive?(acceptor), do: Process.exit(acceptor, :normal)
    end)

    {"http://127.0.0.1:#{port}", replies}
  end

  defp accept_loop(listener, replies, parent, chunked?) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        {headers, body} = read_request(socket, "")
        send(parent, {:request, headers, Jason.decode!(body)})
        reply = Agent.get(replies, & &1)
        {code, value} = if is_tuple(reply), do: reply, else: {200, reply}
        bytes = if is_binary(value), do: value, else: Jason.encode!(value)

        if code == 0 do
          :ok
        else
          if chunked? do
            :gen_tcp.send(socket, [
              "HTTP/1.1 #{code} Test\r\ntransfer-encoding: chunked\r\nconnection: close\r\n\r\n",
              Integer.to_string(byte_size(bytes), 16),
              "\r\n",
              bytes,
              "\r\n0\r\n\r\n"
            ])
          else
            :gen_tcp.send(socket, [
              "HTTP/1.1 #{code} Test\r\ncontent-type: application/json\r\ncontent-length: #{byte_size(bytes)}\r\nconnection: close\r\n\r\n",
              bytes
            ])
          end
        end

        :gen_tcp.close(socket)
        accept_loop(listener, replies, parent, chunked?)

      {:error, :closed} ->
        :ok
    end
  end

  defp read_request(socket, bytes, transport \\ :gen_tcp) do
    case :binary.split(bytes, "\r\n\r\n") do
      [headers, body] ->
        [_, size] = Regex.run(~r/content-length:\s*(\d+)/i, headers)
        length = String.to_integer(size)

        if byte_size(body) >= length do
          {headers, binary_part(body, 0, length)}
        else
          {:ok, next} = transport.recv(socket, 0, 3000)
          read_request(socket, bytes <> next, transport)
        end

      _ ->
        {:ok, next} = transport.recv(socket, 0, 3000)
        read_request(socket, bytes <> next, transport)
    end
  end
end
