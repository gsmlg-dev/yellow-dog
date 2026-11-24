defmodule YellowDog.ManagementUI.WorkerChannelTest do
  use ExUnit.Case, async: false
  import Phoenix.ChannelTest
  import Phoenix.ConnTest, only: [get: 2]

  import Phoenix.LiveViewTest,
    only: [element: 2, form: 3, has_element?: 3, live: 2, render_click: 1, render_submit: 1]

  import ExUnit.CaptureLog

  alias YellowDog.Management.{
    DnsCertificates,
    Domain,
    DomainFixtures,
    Repo,
    Worker,
    WorkerConnections
  }

  alias YellowDog.ManagementUI.{WorkerChannel, WorkerSocket}

  @endpoint YellowDog.ManagementUI.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok
  end

  test "socket handshake requires only a canonical UUID worker identity" do
    id = Ecto.UUID.generate()
    assert {:ok, socket} = connect(WorkerSocket, %{"worker_id" => id})
    assert socket.assigns == %{worker_id: id}
    assert WorkerSocket.id(socket) == "worker_socket:" <> id

    for params <- [%{}, %{"worker_id" => "not-a-uuid"}, %{"worker_id" => String.upcase(id)}],
        do: assert(:error = connect(WorkerSocket, params))
  end

  test "join requires exactly a canonical-length token and a report" do
    {:ok, result} = WorkerConnections.create("Shape")
    id = result["worker"]["id"]
    {:ok, socket} = connect(WorkerSocket, %{"worker_id" => id})

    for payload <- [
          %{"report" => report(id)},
          %{"token" => result["token"]},
          %{"token" => String.slice(result["token"], 0, 42), "report" => report(id)},
          %{"token" => nil, "report" => report(id)},
          %{"token" => result["token"], "report" => report(id), "extra" => true},
          report(id)
        ] do
      assert {:error, %{"code" => "unauthorized"}} =
               subscribe_and_join(socket, WorkerChannel, "worker:" <> id, payload)
    end

    assert Repo.get!(Worker, id).last_seen_at == nil
  end

  test "invalid credentials and mismatched topics are rejected" do
    {:ok, first} = WorkerConnections.create("First")
    {:ok, second} = WorkerConnections.create("Second")
    id = first["worker"]["id"]

    assert {:error, %{"code" => "unauthorized"}} = join_worker(id, new_token(), report(id))
    assert {:error, %{"code" => "unauthorized"}} = join_worker(id, second["token"], report(id))

    {:ok, socket} = connect(WorkerSocket, %{"worker_id" => id})

    assert {:error, %{"code" => "unauthorized"}} =
             subscribe_and_join(
               socket,
               WorkerChannel,
               "worker:" <> second["worker"]["id"],
               payload(first["token"], report(id))
             )

    assert {:error, %{"code" => "unauthorized"}} =
             join_worker(id, first["token"], report(second["worker"]["id"]))

    assert {:error, %{"code" => "invalid_report"}} =
             join_worker(id, first["token"], Map.put(report(id), "capabilities", ["dhcpv4"]))

    assert Repo.get!(Worker, id).last_seen_at == nil
  end

  test "the credential never appears in socket or channel state" do
    {:ok, result} = WorkerConnections.create("State")
    id = result["worker"]["id"]
    assert {:ok, _, socket} = join_worker(id, result["token"], report(id))
    assert_push "target", %{"target" => nil}
    refute inspect(socket) =~ result["token"]
    refute inspect(:sys.get_state(socket.channel_pid)) =~ result["token"]
  end

  test "a database failure during join is reported as unavailable without logging the token" do
    {:ok, result} = WorkerConnections.create("Outage")
    id = result["worker"]["id"]
    {:ok, socket} = connect(WorkerSocket, %{"worker_id" => id})
    # Releasing the Sandbox connection makes every Repo call in the channel raise.
    :ok = Ecto.Adapters.SQL.Sandbox.checkin(Repo)

    log =
      capture_log(fn ->
        assert {:error, %{"code" => "unavailable"}} =
                 subscribe_and_join(
                   socket,
                   WorkerChannel,
                   "worker:" <> id,
                   payload(result["token"], report(id))
                 )
      end)

    assert log =~ "Worker channel join failed"
    refute log =~ result["token"]
  end

  test "a database failure after join crashes the channel without logging the token" do
    {:ok, result} = WorkerConnections.create("Later outage")
    id = result["worker"]["id"]
    assert {:ok, _, socket} = join_worker(id, result["token"], report(id))
    assert_push "target", %{"target" => nil}
    Process.unlink(socket.channel_pid)
    monitor = Process.monitor(socket.channel_pid)
    :ok = Ecto.Adapters.SQL.Sandbox.checkin(Repo)

    log =
      capture_log(fn ->
        push(socket, "report", report(id))
        assert_receive {:DOWN, ^monitor, :process, _, _}, 1_000
        Process.sleep(50)
      end)

    assert log =~ "Last message"
    refute log =~ result["token"]
  end

  test "join records contact and pushes the current target, then confirm pushes the new one" do
    {:ok, result} = WorkerConnections.create("Joined")
    id = result["worker"]["id"]

    assert {:ok, reply, socket} = join_worker(id, result["token"], report(id))
    assert reply == %{}
    assert_push "target", %{"target" => nil}
    assert %DateTime{} = Repo.get!(Worker, id).last_seen_at

    mutate("put_service", DomainFixtures.service(id, 1))
    target = mutate("confirm_target", %{"worker_id" => id, "expected_revision" => 2})
    revision = target["revision"]
    expected = Map.take(target, ~w(revision digest plan))
    assert_push "target", %{"target" => %{"revision" => ^revision} = pushed}, 1_000
    assert pushed == expected

    ref = push(socket, "report", report(id))
    assert_reply ref, :ok, %{}
    refute_push "target", _

    applied =
      Map.merge(report(id), %{
        "applied_revision" => revision,
        "applied_digest" => target["digest"],
        "services" => %{"dns" => %{"state" => "running"}}
      })

    ref = push(socket, "report", applied)
    assert_reply ref, :ok, %{}
    assert {:ok, %{"applied_revision" => ^revision}} = Domain.get_worker(id)

    protocols = %{
      "udp" => %{"state" => "running", "port" => 53, "addresses" => ["::1", "127.0.0.1"]},
      "tcp" => %{
        "state" => "error",
        "port" => 53,
        "addresses" => ["127.0.0.1"],
        "failure" => %{"address" => "127.0.0.1", "reason" => "eaddrinuse"}
      }
    }

    observations = %{"dns" => %{"state" => "partial", "protocols" => protocols}}
    ref = push(socket, "report", Map.put(applied, "services", observations))
    assert_reply ref, :ok, %{}
    assert {:ok, %{"reported_services" => ^observations}} = Domain.get_worker(id)

    ref = push(socket, "report", Map.put(applied, "applied_revision", 999))
    assert_reply ref, :error, %{"code" => "invalid_report"}
    assert Process.alive?(socket.channel_pid)
  end

  test "join pushes an already confirmed target and reports push only newer revisions" do
    {:ok, result} = WorkerConnections.create("Existing")
    id = result["worker"]["id"]
    mutate("put_service", DomainFixtures.service(id, 1))
    target = mutate("confirm_target", %{"worker_id" => id, "expected_revision" => 2})

    assert {:ok, _, socket} = join_worker(id, result["token"], report(id))
    revision = target["revision"]
    assert_push "target", %{"target" => %{"revision" => ^revision}}

    ref = push(socket, "report", report(id))
    assert_reply ref, :ok, %{}
    refute_push "target", _
  end

  test "certificate catalog delivers rotations and protects both saved and active DNS references" do
    {:ok, view, _html} = live(Phoenix.ConnTest.build_conn(), "/system/certificates")
    initial = certificate("Initial DNS certificate")
    view |> form("#certificate-form", certificate: initial) |> render_submit()
    assert [%{id: certificate_id, revision: 1}] = DnsCertificates.list()

    {:ok, enrolled} = WorkerConnections.create("DNS Worker")
    worker_id = enrolled["worker"]["id"]
    assert {:ok, _, channel} = join_worker(worker_id, enrolled["token"], report(worker_id))
    assert_push "target", %{"target" => nil}

    config = %{
      "listen" => %{"mode" => "all_ipv4"},
      "transports" => %{"dot" => %{"enabled" => true, "certificate_id" => certificate_id}}
    }

    service = %{
      "worker_id" => worker_id,
      "expected_revision" => 1,
      "desired_state" => "running",
      "config" => config
    }

    missing =
      put_in(service, ["config", "transports", "dot", "certificate_id"], Ecto.UUID.generate())

    assert {:error, %{code: "certificate_not_found"}} =
             Domain.mutate("put_service", missing, "operator", Ecto.UUID.generate())

    mutate("put_service", service)
    row = "#certificate-#{certificate_id}"
    view |> element("#{row} button[phx-click=delete]") |> render_click()
    assert has_element?(view, "#certificate-references", worker_id <> " · DOT")
    refute_push "dns_certificates", _

    mutate("confirm_target", %{"worker_id" => worker_id, "expected_revision" => 2})

    assert_push "dns_certificates",
                %{"certificates" => [%{"id" => ^certificate_id, "revision" => 1}]},
                1_000

    assert_push "target", %{"target" => %{"revision" => 1, "plan" => plan}}, 1_000
    refute Map.has_key?(hd(plan["services"])["config"]["transports"]["dot"], "private_key_pem")

    ref =
      push(
        channel,
        "report",
        Map.put(report(worker_id), "apply_error", "invalid_dns_certificate")
      )

    assert_reply ref, :ok, %{}
    assert {:ok, %{"apply_error" => "invalid_dns_certificate"}} = Domain.get_worker(worker_id)

    replacement = certificate("Updated DNS certificate")
    view |> element("#{row} button[phx-click=edit]") |> render_click()

    view
    |> form("#certificate-form-#{certificate_id}", certificate: replacement)
    |> render_submit()

    assert_push "dns_certificates",
                %{"certificates" => [%{"id" => ^certificate_id, "revision" => 2}]},
                1_000

    refute_push "target", _

    monitor = Process.monitor(channel.channel_pid)
    Process.unlink(channel.channel_pid)
    leave(channel)
    assert_receive {:DOWN, ^monitor, :process, _, {:shutdown, :left}}

    view |> element("#{row} button[phx-click=edit]") |> render_click()

    view
    |> form("#certificate-form-#{certificate_id}", certificate: certificate("Offline rotation"))
    |> render_submit()

    assert {:ok, _, _} = join_worker(worker_id, enrolled["token"], report(worker_id))

    assert_push "dns_certificates",
                %{"certificates" => [%{"id" => ^certificate_id, "revision" => 3}]},
                1_000

    assert_push "target", %{"target" => %{"revision" => 1}}, 1_000

    closed = put_in(service, ["config", "transports", "dot", "enabled"], false)
    mutate("put_service", Map.put(closed, "expected_revision", 3))
    view |> element("#{row} button[phx-click=delete]") |> render_click()
    assert has_element?(view, "#certificate-references", worker_id <> " · DOT")

    mutate("confirm_target", %{"worker_id" => worker_id, "expected_revision" => 4})
    view |> element("#{row} button[phx-click=delete]") |> render_click()
    assert has_element?(view, "#certificate-references", worker_id <> " · DOT")

    unlinked =
      update_in(closed, ["config", "transports", "dot"], &Map.delete(&1, "certificate_id"))

    mutate("put_service", Map.put(unlinked, "expected_revision", 5))
    mutate("confirm_target", %{"worker_id" => worker_id, "expected_revision" => 6})
    view |> element("#{row} button[phx-click=delete]") |> render_click()
    assert DnsCertificates.list() == []
  end

  test "token rotation rejects the next report and stops the joined channel" do
    {:ok, result} = WorkerConnections.create("Rotated")
    id = result["worker"]["id"]
    assert {:ok, _, socket} = join_worker(id, result["token"], report(id))
    assert_push "target", %{"target" => nil}
    monitor = Process.monitor(socket.channel_pid)
    Process.unlink(socket.channel_pid)

    assert {:ok, _} = WorkerConnections.rotate(id)
    ref = push(socket, "report", report(id))
    assert_reply ref, :error, %{"code" => "unauthorized"}
    assert_receive {:DOWN, ^monitor, :process, _, :normal}
  end

  test "token rotation stops target pushes to a silent joined channel" do
    {:ok, result} = WorkerConnections.create("Silent")
    id = result["worker"]["id"]
    mutate("put_service", DomainFixtures.service(id, 1))
    assert {:ok, _, socket} = join_worker(id, result["token"], report(id))
    assert_push "target", %{"target" => nil}
    monitor = Process.monitor(socket.channel_pid)
    Process.unlink(socket.channel_pid)

    assert {:ok, _} = WorkerConnections.rotate(id)
    {:ok, worker} = Domain.get_worker(id)
    mutate("confirm_target", %{"worker_id" => id, "expected_revision" => worker["revision"]})

    assert_receive {:DOWN, ^monitor, :process, _, :normal}, 1_000
    refute_push "target", _
  end

  test "anonymous enrollment admits a new UUID only while enabled" do
    id = Ecto.UUID.generate()
    token = new_token()

    assert {:error, %{"code" => "unauthorized"}} = join_worker(id, token, report(id))
    assert Repo.get(Worker, id) == nil

    mutate("set_worker_enrollment", %{"allow_anonymous" => true})
    assert {:ok, _, _} = join_worker(id, token, report(id))
    assert_push "target", %{"target" => nil}
    assert Repo.get!(Worker, id).connection_token_hash == :crypto.hash(:sha256, token)
  end

  describe "real HTTP listener" do
    setup do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
      %{port: start_listener()}
    end

    test "upgrades exactly /api/worker/connect with only a UUID worker_id", %{port: port} do
      id = Ecto.UUID.generate()
      assert {101, tcp} = upgrade(port, "/api/worker/connect?vsn=2.0.0&worker_id=#{id}")
      :gen_tcp.close(tcp)

      for path <- [
            "/api/worker/connect?vsn=2.0.0",
            "/api/worker/connect?vsn=2.0.0&worker_id=not-a-uuid",
            "/api/worker/connect/websocket?vsn=2.0.0&worker_id=#{id}"
          ] do
        assert {status, tcp} = upgrade(port, path)
        assert status != 101, path
        :gen_tcp.close(tcp)
      end

      {:ok, tcp} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])

      :ok =
        :gen_tcp.send(
          tcp,
          "POST /api/worker/connect HTTP/1.1\r\nhost: 127.0.0.1\r\n" <>
            "content-type: application/json\r\ncontent-length: 2\r\n\r\n{}"
        )

      assert {:ok, "HTTP/1.1 400" <> _} = :gen_tcp.recv(tcp, 0, 5_000)
      :gen_tcp.close(tcp)
    end

    test "joins over the wire and rotation closes the live socket", %{port: port} do
      {:ok, result} = WorkerConnections.create("Wire")
      id = result["worker"]["id"]
      assert {101, tcp} = upgrade(port, "/api/worker/connect?vsn=2.0.0&worker_id=#{id}")

      join = ["1", "1", "worker:" <> id, "phx_join", payload(result["token"], report(id))]
      level = Logger.level()
      Logger.configure(level: :debug)

      {messages, log} =
        try do
          with_log([level: :debug], fn ->
            :ok = :gen_tcp.send(tcp, client_frame(0x1, Jason.encode!(join)))
            joined = for _ <- 1..2, do: tcp |> read_frame() |> elem(1) |> Jason.decode!()
            report = ["1", "2", "worker:" <> id, "report", report(id)]
            :ok = :gen_tcp.send(tcp, client_frame(0x1, Jason.encode!(report)))
            reply = tcp |> read_frame() |> elem(1) |> Jason.decode!()
            assert ["1", "2", _, "phx_reply", %{"status" => "ok"}] = reply
            joined
          end)
        after
          Logger.configure(level: level)
        end

      assert log =~ "worker:" <> id
      refute log =~ result["token"]

      assert ["1", "1", "worker:" <> id, "phx_reply", %{"status" => "ok", "response" => %{}}] in messages

      assert ["1", nil, "worker:" <> ^id, "target", %{"target" => nil}] =
               Enum.find(messages, &(Enum.at(&1, 3) == "target"))

      assert {:ok, _} = WorkerConnections.rotate(id)
      assert closed?(tcp)
    end

    test "rejects frames over 64 KiB", %{port: port} do
      id = Ecto.UUID.generate()
      assert {101, tcp} = upgrade(port, "/api/worker/connect?vsn=2.0.0&worker_id=#{id}")
      heartbeat = fn pad -> Jason.encode!([nil, "1", "phoenix", "heartbeat", %{"pad" => pad}]) end

      :ok = :gen_tcp.send(tcp, client_frame(0x1, heartbeat.("")))
      assert {0x1, reply} = read_frame(tcp)
      assert [nil, "1", "phoenix", "phx_reply", %{"status" => "ok"}] = Jason.decode!(reply)

      oversized = heartbeat.(String.duplicate("a", 65_536))
      assert byte_size(oversized) > 65_536
      :ok = :gen_tcp.send(tcp, client_frame(0x1, oversized))
      assert closed?(tcp)
    end
  end

  defp start_listener do
    config = [
      server: true,
      http: [ip: {127, 0, 0, 1}, port: 0],
      websocket_paths: @endpoint.config(:websocket_paths)
    ]

    for spec <- Gaoxy.PhoenixAdapter.child_specs(@endpoint, config), do: start_supervised!(spec)
    {:ok, {_, port}} = Gaoxy.PhoenixAdapter.server_info(@endpoint, :http)
    port
  end

  defp upgrade(port, path) do
    {:ok, tcp} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])

    request =
      Enum.join(
        [
          "GET #{path} HTTP/1.1",
          "host: 127.0.0.1:#{port}",
          "upgrade: websocket",
          "connection: Upgrade",
          "sec-websocket-version: 13",
          "sec-websocket-key: dGhlIHNhbXBsZSBub25jZQ=="
        ],
        "\r\n"
      )

    :ok = :gen_tcp.send(tcp, request <> "\r\n\r\n")
    :ok = :inet.setopts(tcp, packet: :http_bin)
    {:ok, {:http_response, _, status, _}} = :gen_tcp.recv(tcp, 0, 5_000)
    skip_headers(tcp)
    :ok = :inet.setopts(tcp, packet: :raw)
    {status, tcp}
  end

  defp skip_headers(tcp) do
    case :gen_tcp.recv(tcp, 0, 5_000) do
      {:ok, :http_eoh} -> :ok
      {:ok, {:http_header, _, _, _, _}} -> skip_headers(tcp)
    end
  end

  defp client_frame(opcode, payload) do
    mask = :crypto.strong_rand_bytes(4)
    size = byte_size(payload)

    length =
      cond do
        size < 126 -> <<1::1, size::7>>
        size < 65_536 -> <<1::1, 126::7, size::16>>
        true -> <<1::1, 127::7, size::64>>
      end

    key = mask |> :binary.copy(div(size, 4) + 1) |> binary_part(0, size)
    <<1::1, 0::3, opcode::4>> <> length <> mask <> :crypto.exor(payload, key)
  end

  defp read_frame(tcp) do
    {:ok, <<_::4, opcode::4, 0::1, short::7>>} = :gen_tcp.recv(tcp, 2, 5_000)

    size =
      case short do
        126 -> tcp |> recv!(2) |> :binary.decode_unsigned()
        127 -> tcp |> recv!(8) |> :binary.decode_unsigned()
        size -> size
      end

    {opcode, if(size == 0, do: "", else: recv!(tcp, size))}
  end

  defp recv!(tcp, size) do
    {:ok, data} = :gen_tcp.recv(tcp, size, 5_000)
    data
  end

  # The server either sends a close frame or drops the connection.
  defp closed?(tcp) do
    case :gen_tcp.recv(tcp, 2, 5_000) do
      {:ok, <<_::4, 0x8::4, _::8>>} -> true
      {:error, :closed} -> true
      _ -> false
    end
  end

  defp join_worker(id, token, report) do
    {:ok, socket} = connect(WorkerSocket, %{"worker_id" => id})
    subscribe_and_join(socket, WorkerChannel, "worker:" <> id, payload(token, report))
  end

  defp payload(token, report), do: %{"token" => token, "report" => report}

  defp report(id) do
    %{
      "worker_id" => id,
      "capabilities" => ["dns"],
      "services" => %{},
      "applied_revision" => nil,
      "applied_digest" => nil,
      "apply_error" => nil
    }
  end

  defp new_token, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

  defp certificate(name) do
    %{cert: der, key: key} = :public_key.pkix_test_root_cert(String.to_charlist(name), [])
    type = elem(key, 0)

    %{
      name: name,
      certificate_pem: :public_key.pem_encode([{:Certificate, der, :not_encrypted}]),
      private_key_pem: :public_key.pem_encode([:public_key.pem_entry_encode(type, key)])
    }
  end

  defp mutate(operation, params) do
    assert {:ok, result} = Domain.mutate(operation, params, "operator", Ecto.UUID.generate())
    result
  end
end
