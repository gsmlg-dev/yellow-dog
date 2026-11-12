defmodule YellowDog.Management.WorkerConnectionsTest do
  use ExUnit.Case, async: false
  import Ecto.Query

  alias YellowDog.Management.{
    Audit,
    Domain,
    DomainFixtures,
    Idempotency,
    Repo,
    Worker,
    WorkerConnections
  }

  setup tags do
    unless tags[:unboxed], do: :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok
  end

  test "anonymous enrollment is disabled by default without business or credential writes" do
    id = Ecto.UUID.generate()
    assert Domain.worker_enrollment_settings() == %{"allow_anonymous" => false}
    assert request(anonymous_token(), anonymous_report(id)) == "unauthorized"
    assert Repo.aggregate(Worker, :count) == 0
    assert Repo.aggregate(Audit, :count) == 0
    assert Repo.aggregate(Idempotency, :count) == 0
  end

  test "enrollment setting is an audited idempotent strict boolean command" do
    key = Ecto.UUID.generate()
    params = %{"allow_anonymous" => true}
    assert {:ok, ^params} = Domain.mutate("set_worker_enrollment", params, "operator", key)
    assert {:ok, ^params} = Domain.mutate("set_worker_enrollment", params, "operator", key)
    assert Domain.worker_enrollment_settings() == params
    assert Repo.aggregate(Audit, :count) == 1
    assert Repo.aggregate(Idempotency, :count) == 1

    assert {:error, %{code: "idempotency_conflict"}} =
             Domain.mutate(
               "set_worker_enrollment",
               %{"allow_anonymous" => false},
               "operator",
               key
             )

    for invalid <- [
          %{},
          %{"allow_anonymous" => "true"},
          %{"allow_anonymous" => nil},
          %{"allow_anonymous" => false, "extra" => true}
        ] do
      assert {:error, _} =
               Domain.mutate("set_worker_enrollment", invalid, "operator", Ecto.UUID.generate())

      assert Domain.worker_enrollment_settings() == params
    end
  end

  test "anonymous first contact and lost-response retry preserve one hash-only Worker" do
    mutate("set_worker_enrollment", %{"allow_anonymous" => true})
    id = Ecto.UUID.generate()
    token = anonymous_token()
    report = anonymous_report(id)
    assert request(token, report) == :ok
    assert request(token, report) == :ok
    assert Repo.aggregate(Worker, :count) == 1
    assert Repo.get!(Worker, id).connection_token_hash == :crypto.hash(:sha256, token)
    assert {:ok, worker} = Domain.get_worker(id)
    assert worker["name"] == "Worker #{id}"
    assert worker["services"] == []
    assert worker["assignments"] == []
    assert worker["connection_status"] == "connected"
    assert Repo.aggregate(Audit, :count) == 2
    assert Repo.aggregate(Idempotency, :count) == 2

    refute Jason.encode!([
             Domain.list_workers(),
             Domain.list_audit(),
             Enum.map(Repo.all(Idempotency), & &1.result)
           ]) =~ token

    mutate("set_worker_enrollment", %{"allow_anonymous" => false})
    assert request(token, report) == :ok
    assert request(anonymous_token(), anonymous_report(Ecto.UUID.generate())) == "unauthorized"
  end

  test "anonymous enrollment cannot replace existing or revoked credentials" do
    mutate("set_worker_enrollment", %{"allow_anonymous" => true})
    id = Ecto.UUID.generate()
    token = anonymous_token()
    report = anonymous_report(id)
    assert request(token, report) == :ok
    before = Repo.get!(Worker, id)
    assert request(anonymous_token(), report) == "unauthorized"
    assert Repo.get!(Worker, id) == before
    assert {:ok, rotated} = WorkerConnections.rotate(id)
    assert request(token, report) == "unauthorized"
    assert request(rotated["token"], report) == :ok
    assert Repo.aggregate(Worker, :count) == 1
  end

  test "new identity requires UUID, canonical credential and an empty initial report" do
    mutate("set_worker_enrollment", %{"allow_anonymous" => true})
    report = anonymous_report(Ecto.UUID.generate())

    invalid = [
      Map.put(report, "worker_id", "not-a-uuid"),
      Map.put(report, "services", %{"dns" => %{"state" => "running"}}),
      Map.put(report, "applied_revision", 1),
      Map.put(report, "apply_error", "apply_failed"),
      Map.put(report, "token", "unsafe"),
      Map.put(report, "capabilities", ["dns", "dhcpv4"])
    ]

    for report <- invalid, do: assert(request(anonymous_token(), report) == "unauthorized")

    for token <- [String.duplicate("!", 43), String.duplicate("A", 42), nil],
        do: assert(request(token, report) == "unauthorized")

    assert Repo.aggregate(Worker, :count) == 0
    assert Repo.aggregate(Audit, :count) == 1
    assert Repo.aggregate(Idempotency, :count) == 1
  end

  @tag :unboxed
  test "independent simultaneous requests enroll exactly once and disable blocks admission" do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      id = Ecto.UUID.generate()
      token = anonymous_token()
      setting_key = Ecto.UUID.generate()
      disable_key = Ecto.UUID.generate()
      parent = self()
      assert Repo.aggregate(Audit, :count) == 0

      try do
        assert {:ok, _} =
                 Domain.mutate(
                   "set_worker_enrollment",
                   %{"allow_anonymous" => true},
                   "operator",
                   setting_key
                 )

        tasks =
          for _ <- 1..4 do
            Task.async(fn ->
              Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
                WorkerConnections.connect(token, anonymous_report(id))
              end)
            end)
          end

        for task <- tasks,
            do: assert({:ok, %{"worker_id" => ^id, "target" => nil}} = Task.await(task))

        assert Repo.aggregate(from(w in Worker, where: w.id == ^id), :count) == 1

        assert Repo.aggregate(
                 from(a in Audit,
                   where: a.operation == "create_worker" and a.request["id"] == ^id
                 ),
                 :count
               ) == 1

        disabling =
          Task.async(fn ->
            Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
              Repo.transaction(fn ->
                assert {:ok, _} =
                         Domain.mutate(
                           "set_worker_enrollment",
                           %{"allow_anonymous" => false},
                           "operator",
                           disable_key
                         )

                send(parent, :disable_locked)

                receive do
                  :commit_disable -> :ok
                end
              end)
            end)
          end)

        assert_receive :disable_locked
        blocked_id = Ecto.UUID.generate()

        connecting =
          Task.async(fn ->
            Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
              %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
              send(parent, {:connecting, backend})
              WorkerConnections.connect(anonymous_token(), anonymous_report(blocked_id))
            end)
          end)

        assert_receive {:connecting, backend}
        assert Task.yield(connecting, 100) == nil

        assert %{rows: [["Lock"]]} =
                 Repo.query!("SELECT wait_event_type FROM pg_stat_activity WHERE pid = $1", [
                   backend
                 ])

        send(disabling.pid, :commit_disable)
        assert {:ok, :ok} = Task.await(disabling)
        assert {:error, %{code: "unauthorized"}} = Task.await(connecting)
        assert Repo.get(Worker, blocked_id) == nil
        assert {:ok, _} = WorkerConnections.connect(token, anonymous_report(id))
      after
        # These independent connections commit outside Sandbox. Audits are immutable,
        # so reset the disposable test database rather than deleting audit rows.
        Repo.query!("TRUNCATE management_audits")

        Repo.delete_all(
          from(i in Idempotency,
            where: i.key in ^[setting_key, disable_key, "anonymous_worker:#{id}"]
          )
        )

        Repo.delete_all(from(w in Worker, where: w.id == ^id))
        Repo.query!("UPDATE management_worker_enrollment_settings SET allow_anonymous = false")
      end
    end)
  end

  defp anonymous_token, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  defp anonymous_report(id), do: report(%{"worker" => %{"id" => id}})

  test "name-only enrollment generates unique identities and stores only credential hashes" do
    {:ok, first} = WorkerConnections.create("Office")
    {:ok, second} = WorkerConnections.create("Office")
    assert first["worker"]["id"] != second["worker"]["id"]
    assert first["token"] != second["token"]
    assert {:ok, _} = Ecto.UUID.cast(first["worker"]["id"])
    assert byte_size(first["token"]) == 43
    assert {:ok, worker} = Domain.get_worker(first["worker"]["id"])
    assert worker["name"] == "Office"
    assert worker["services"] == []
    assert worker["connection_status"] == "not_yet_connected"
    assert worker["status"] == "not_yet_connected"
    assert worker["actual_state"] == "unknown"

    stored = Repo.get!(Worker, worker["id"])
    assert stored.connection_token_hash == :crypto.hash(:sha256, first["token"])
    refute inspect(stored) =~ Base.encode16(stored.connection_token_hash)

    ordinary =
      Jason.encode!([
        Domain.list_workers(),
        worker,
        Repo.all(Audit) |> Enum.map(& &1.result),
        Repo.all(Idempotency) |> Enum.map(& &1.result)
      ])

    refute ordinary =~ first["token"]
    refute ordinary =~ "connection_token_hash"
  end

  test "invalid names leave no enrollment, audit or idempotency rows" do
    for name <- [nil, "", " ", " Office", "Office ", String.duplicate("a", 129), "a" <> <<0>>] do
      assert {:error, %{code: "invalid_request"}} = WorkerConnections.create(name)
    end

    assert Repo.aggregate(Worker, :count) == 0
    assert Repo.aggregate(Audit, :count) == 0
    assert Repo.aggregate(Idempotency, :count) == 0
  end

  test "generated configuration is complete flat TOML with escaped operator text" do
    {:ok, result} = WorkerConnections.create("Office")

    snippet =
      WorkerConnections.bootstrap(
        result["worker"],
        result["token"],
        "https://yellow-dog.gsmlg.net"
      )

    assert {:ok, config} = Toml.decode(snippet)

    assert config == %{
             "worker_id" => result["worker"]["id"],
             "data_dir" => "data",
             "management_url" => "https://yellow-dog.gsmlg.net",
             "token" => result["token"]
           }
  end

  test "credential authentication scopes identity and records contact" do
    {:ok, first} = WorkerConnections.create("First")
    {:ok, second} = WorkerConnections.create("Second")
    report = report(first)
    assert request(nil, report) == "unauthorized"
    assert request(String.duplicate("x", 43), report) == "unauthorized"
    assert request(second["token"], report) == "unauthorized"

    assert request(first["token"], Map.put(report, "worker_id", second["worker"]["id"])) ==
             "unauthorized"

    assert WorkerConnections.connect(first["token"], report) ==
             {:ok, %{"worker_id" => first["worker"]["id"], "target" => nil}}

    assert {:ok, worker} = Domain.get_worker(first["worker"]["id"])
    assert worker["connection_status"] == "connected"
    assert worker["last_seen_at"] != nil
    assert worker["reported_capabilities"] == ["dns"]
    assert worker["reported_services"] == %{}
  end

  test "rotation revokes old tokens and leaves credentials out of audits" do
    {:ok, first} = WorkerConnections.create("Rotate")
    assert request(first["token"], report(first)) == :ok
    {:ok, rotated} = WorkerConnections.rotate(first["worker"]["id"])
    assert rotated["token"] != first["token"]
    assert rotated["worker"]["connection_status"] == "not_yet_connected"
    assert request(first["token"], report(first)) == "unauthorized"
    assert request(rotated["token"], report(rotated)) == :ok
    {:ok, worker} = Domain.get_worker(first["worker"]["id"])
    ordinary = Jason.encode!([Domain.list_audit(), worker])
    refute ordinary =~ first["token"]
    refute ordinary =~ rotated["token"]
    assert Enum.any?(Domain.list_audit(), &(&1["operation"] == "rotate_worker_token"))
    assert {:error, %{code: "not_found"}} = WorkerConnections.rotate("missing")
  end

  test "contact expires without changing reported observations or configuration" do
    {:ok, result} = WorkerConnections.create("Expire")
    assert request(result["token"], report(result)) == :ok
    worker = Repo.get!(Worker, result["worker"]["id"])

    worker
    |> Ecto.Changeset.change(last_seen_at: DateTime.add(DateTime.utc_now(), -46, :second))
    |> Repo.update!()

    assert {:ok, expired} = Domain.get_worker(worker.id)
    assert expired["connection_status"] == "offline"
    assert expired["services"] == []
    assert request(result["token"], report(result)) == :ok
    assert {:ok, reconnected} = Domain.get_worker(worker.id)
    assert reconnected["connection_status"] == "connected"
  end

  test "malformed or excessive observations do not record contact" do
    {:ok, result} = WorkerConnections.create("Reports")
    report = report(result)
    excessive = Map.new(1..65, &{"dns-#{&1}", %{"state" => "running"}})

    for invalid <- [
          Map.delete(report, "services"),
          Map.put(report, "capabilities", ["dns", "dhcpv4"]),
          Map.put(report, "services", excessive),
          Map.put(report, "services", %{
            "dns" => %{"state" => "running", "token" => result["token"]}
          }),
          Map.put(report, "services", %{"bad/id" => %{"state" => "running"}}),
          Map.put(report, "services", %{"dns" => %{"state" => "unknown"}}),
          Map.put(report, "applied_revision", 1),
          Map.merge(report, %{
            "applied_revision" => 9_223_372_036_854_775_808,
            "applied_digest" => String.duplicate("0", 64)
          }),
          Map.put(report, "apply_error", result["token"]),
          Map.put(report, "token", result["token"])
        ] do
      assert request(result["token"], invalid) == "invalid_report"
    end

    assert {:ok, worker} = Domain.get_worker(result["worker"]["id"])
    assert worker["last_seen_at"] == nil
    assert worker["reported_services"] == %{}
  end

  test "only confirmed targets are delivered and applied claims must match a persisted target" do
    {:ok, result} = WorkerConnections.create("Publish")
    id = result["worker"]["id"]
    mutate("put_service", DomainFixtures.service(id, 1))
    assert {:ok, %{"target" => nil}} = WorkerConnections.connect(result["token"], report(result))
    target = mutate("confirm_target", %{"worker_id" => id, "expected_revision" => 2})

    assert {:ok, %{"target" => delivered}} =
             WorkerConnections.connect(result["token"], report(result))

    assert delivered == Map.take(target, ~w(revision digest plan))

    applied =
      report(result)
      |> Map.merge(%{
        "applied_revision" => target["revision"],
        "applied_digest" => target["digest"],
        "services" => %{"dns" => %{"state" => "running"}}
      })

    assert request(result["token"], applied) == :ok

    assert request(result["token"], Map.put(applied, "applied_digest", String.duplicate("0", 64))) ==
             "invalid_report"

    assert request(result["token"], Map.put(applied, "applied_revision", 999)) == "invalid_report"
    assert {:ok, worker} = Domain.get_worker(id)
    assert worker["applied_revision"] == target["revision"]
    assert worker["reported_services"] == applied["services"]

    mutate("put_service", DomainFixtures.service(id, worker["revision"], "stopped"))
    assert {:ok, %{"target" => ^delivered}} = WorkerConnections.connect(result["token"], applied)
  end

  defp report(result) do
    %{
      "worker_id" => result["worker"]["id"],
      "capabilities" => ["dns"],
      "services" => %{},
      "applied_revision" => nil,
      "applied_digest" => nil,
      "apply_error" => nil
    }
  end

  defp request(token, report) do
    case WorkerConnections.connect(token, report) do
      {:ok, _} -> :ok
      {:error, %{code: code}} -> code
    end
  end

  defp mutate(operation, params) do
    assert {:ok, result} = Domain.mutate(operation, params, "operator", Ecto.UUID.generate())
    result
  end
end
