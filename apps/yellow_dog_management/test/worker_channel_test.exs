defmodule YellowDog.ManagementUI.WorkerChannelTest do
  use ExUnit.Case, async: false
  import Phoenix.ChannelTest

  alias YellowDog.Management.{Domain, DomainFixtures, Repo, Worker, WorkerConnections}
  alias YellowDog.ManagementUI.{WorkerChannel, WorkerSocket}

  @endpoint YellowDog.ManagementUI.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok
  end

  test "socket requires a canonical-length token header and UUID worker identity" do
    id = Ecto.UUID.generate()
    token = new_token()
    assert {:ok, socket} = connect(WorkerSocket, %{"worker_id" => id}, connect_info: info(token))
    assert socket.assigns.worker_id == id
    assert WorkerSocket.id(socket) == "worker_socket:" <> id
    refute inspect(socket) =~ token

    assert :error = connect(WorkerSocket, %{"worker_id" => id}, connect_info: %{x_headers: []})

    assert :error =
             connect(WorkerSocket, %{"worker_id" => id},
               connect_info: info(String.duplicate("a", 42))
             )

    assert :error =
             connect(WorkerSocket, %{"worker_id" => id, "token" => token},
               connect_info: %{x_headers: []}
             )

    assert :error =
             connect(WorkerSocket, %{"worker_id" => "not-a-uuid"}, connect_info: info(token))

    assert :error = connect(WorkerSocket, %{}, connect_info: info(token))
  end

  test "invalid credentials and mismatched topics are rejected" do
    {:ok, first} = WorkerConnections.create("First")
    {:ok, second} = WorkerConnections.create("Second")
    id = first["worker"]["id"]

    assert {:error, %{"code" => "unauthorized"}} =
             join_worker(id, new_token(), report(id))

    assert {:error, %{"code" => "unauthorized"}} =
             join_worker(id, second["token"], report(id))

    {:ok, socket} = socket_for(id, first["token"])

    assert {:error, %{"code" => "unauthorized"}} =
             subscribe_and_join(
               socket,
               WorkerChannel,
               "worker:" <> second["worker"]["id"],
               report(id)
             )

    assert {:error, %{"code" => "unauthorized"}} =
             subscribe_and_join(
               socket,
               WorkerChannel,
               "worker:" <> id,
               report(second["worker"]["id"])
             )

    assert {:error, %{"code" => "invalid_report"}} =
             join_worker(id, first["token"], Map.put(report(id), "capabilities", ["dhcpv4"]))

    assert Repo.get!(Worker, id).last_seen_at == nil
  end

  test "join records contact and pushes the current target, then confirm pushes the new one" do
    {:ok, result} = WorkerConnections.create("Joined")
    id = result["worker"]["id"]

    assert {:ok, reply, socket} = join_worker(id, result["token"], report(id))
    assert reply == %{}
    assert_push "target", %{"target" => nil}
    assert %DateTime{} = Repo.get!(Worker, id).last_seen_at
    refute inspect(socket) =~ result["token"]

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

  test "the Worker socket upgrades over HTTP at exactly /api/worker/connect" do
    {:ok, result} = WorkerConnections.create("Handshake")
    id = result["worker"]["id"]
    port = start_listener()

    upgrade = fn path, token ->
      {:ok, tcp} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])

      headers =
        [
          "GET #{path}?vsn=2.0.0&worker_id=#{id} HTTP/1.1",
          "host: 127.0.0.1:#{port}",
          "upgrade: websocket",
          "connection: Upgrade",
          "sec-websocket-version: 13",
          "sec-websocket-key: dGhlIHNhbXBsZSBub25jZQ=="
        ] ++ if(token, do: ["x-yellow-dog-worker-token: " <> token], else: [])

      :ok = :gen_tcp.send(tcp, Enum.join(headers, "\r\n") <> "\r\n\r\n")
      {:ok, response} = :gen_tcp.recv(tcp, 0, 5_000)
      :gen_tcp.close(tcp)
      response
    end

    assert upgrade.("/api/worker/connect", result["token"]) =~ ~r/\AHTTP\/1\.1 101/
    assert upgrade.("/api/worker/connect", nil) =~ ~r/\AHTTP\/1\.1 403/
    refute upgrade.("/api/worker/connect/websocket", result["token"]) =~ ~r/\AHTTP\/1\.1 101/

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

  defp start_listener do
    config =
      @endpoint.config(:websocket_paths)
      |> then(&[server: true, http: [ip: {127, 0, 0, 1}, port: 0], websocket_paths: &1])

    for spec <- Gaoxy.PhoenixAdapter.child_specs(@endpoint, config), do: start_supervised!(spec)
    {:ok, {_, port}} = Gaoxy.PhoenixAdapter.server_info(@endpoint, :http)
    port
  end

  defp join_worker(id, token, report) do
    {:ok, socket} = socket_for(id, token)
    subscribe_and_join(socket, WorkerChannel, "worker:" <> id, report)
  end

  defp socket_for(id, token),
    do: connect(WorkerSocket, %{"worker_id" => id}, connect_info: info(token))

  defp info(token), do: %{x_headers: [{"x-yellow-dog-worker-token", token}], peer_data: nil}

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

  defp mutate(operation, params) do
    assert {:ok, result} = Domain.mutate(operation, params, "operator", Ecto.UUID.generate())
    result
  end
end
