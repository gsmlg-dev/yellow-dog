defmodule YellowDog.Management.NodeDatabaseRecoveryTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Ecto.Query

  alias YellowDog.Management.{Audit, Database, Domain, Repo, Worker, WorkerConnections}
  @endpoint YellowDog.ManagementUI.Endpoint

  setup do
    unless System.get_env("YELLOW_DOG_PHASE1_PG_DATA_DIR"),
      do:
        raise("Fault injection requires scripts/e2e/phase1_postgres.sh and disposable PostgreSQL")

    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        Repo.query!("DROP POLICY IF EXISTS node_fault ON management_workers")
        Repo.query!("ALTER TABLE management_workers DISABLE ROW LEVEL SECURITY")
        Repo.query!("DROP FUNCTION IF EXISTS public.node_recovery_available()")

        Repo.query!(
          "TRUNCATE management_workers, management_audits, management_idempotency CASCADE"
        )

        if Repo.query!("SELECT 1 FROM pg_roles WHERE rolname = 'node_recovery_fault'").num_rows ==
             1 do
          Repo.query!("DROP OWNED BY node_recovery_fault")
          Repo.query!("DROP ROLE node_recovery_fault")
        end
      end)
    end)

    {:ok, connection} = WorkerConnections.create("Same name")
    %{worker: connection["worker"]}
  end

  test "availability errors are contained without hiding programming errors" do
    assert {:error, %{code: "database_unavailable"}} =
             Database.read(fn -> raise DBConnection.ConnectionError, "test checkout failure" end)

    for code <- [:undefined_table, :syntax_error] do
      assert_raise Postgrex.Error, fn ->
        Database.read(fn ->
          raise %Postgrex.Error{
            postgres: %{
              code: code,
              pg_code: "42000",
              severity: "ERROR",
              message: "injected programming error"
            }
          }
        end)
      end
    end

    assert_raise ArgumentError, fn -> Database.credential(fn -> raise ArgumentError end, "id") end

    assert {:error, %{code: "database_constraint"}} =
             Database.credential(
               fn ->
                 raise %Postgrex.Error{
                   postgres: %{
                     code: :unique_violation,
                     pg_code: "23505",
                     severity: "ERROR",
                     message: "injected constraint"
                   }
                 }
               end,
               "id"
             )
  end

  test "failed PostgreSQL observation preserves dirty input, revision and preview until recovery",
       %{
         worker: worker
       } do
    {:ok, editor, _} = live(build_conn(), "/server/#{worker["id"]}/dashboard")
    {:ok, target, _} = live(build_conn(), "/server/#{worker["id"]}/targets")

    render_change(editor, "validate_worker", %{
      "worker" => %{"name" => "Local edit", "profile_name" => "custom"}
    })

    render_click(target, "preview")
    original = socket(editor)
    preview = socket(target).assigns.preview
    target_intent = socket(target).assigns.submission_id
    install_read_failure()

    with_failure(fn ->
      # Reproduce the original uncontained application read before exercising UI containment.
      assert_raise Postgrex.Error, fn -> Domain.get_worker(worker["id"]) end
    end)

    with_failure(fn ->
      send(editor.pid, :refresh_connection)
      assert has_element?(editor, "#node-observation-error", "could not read PostgreSQL")
      assert Process.alive?(editor.pid)
      assert has_element?(editor, "input[name='worker[name]'][value='Local edit']")
      assert socket(editor).assigns.worker["revision"] == original.assigns.worker["revision"]
      assert socket(editor).assigns.submission_id == original.assigns.submission_id
    end)

    with_failure(fn ->
      send(target.pid, :refresh_connection)
      assert has_element?(target, "#node-observation-error")
      assert socket(target).assigns.preview == preview
      render_click(target, "preview")
      assert Process.alive?(target.pid)
      assert has_element?(target, "#node-observation-error", "could not read PostgreSQL")
      assert socket(target).assigns.preview == preview
      assert socket(target).assigns.submission_id == target_intent
      assert socket(target).assigns.worker["revision"] == original.assigns.worker["revision"]
      assert has_element?(editor, "input[name='worker[name]'][value='Local edit']")
    end)

    render_click(target, "preview")
    refute has_element?(target, "#node-observation-error")
    assert socket(target).assigns.preview == preview
    assert socket(target).assigns.submission_id != target_intent
    send(editor.pid, :refresh_connection)
    send(target.pid, :refresh_connection)
    refute has_element?(editor, "#node-observation-error")
    refute has_element?(target, "#node-observation-error")
    assert has_element?(editor, "input[name='worker[name]'][value='Local edit']")
    assert socket(target).assigns.preview == preview
    assert socket(editor).assigns.worker["revision"] == original.assigns.worker["revision"]
    # Manually induced observations do not schedule additional timer chains.
    assert Enum.count(elem(Process.info(editor.pid, :messages), 1), &(&1 == :refresh_connection)) ==
             0
  end

  test "failed same-Worker route changes retire the old service scope and recover explicitly", %{
    worker: worker
  } do
    {:ok, first} =
      Domain.mutate(
        "put_service",
        YellowDog.Management.DomainFixtures.service(worker["id"], worker["revision"], "stopped"),
        "operator",
        Ecto.UUID.generate()
      )

    {:ok, second} =
      Domain.mutate(
        "put_service",
        YellowDog.Management.DomainFixtures.service(
          worker["id"],
          first["worker_revision"],
          "stopped"
        )
        |> Map.put("id", "dns-b"),
        "operator",
        Ecto.UUID.generate()
      )

    before = Domain.list_services(worker["id"])
    audit_count = Repo.aggregate(Audit, :count)
    install_read_failure()

    for {destination, expected_id} <- [
          {"/server/#{worker["id"]}/services/#{second["id"]}/edit", "dns-b"},
          {"/server/#{worker["id"]}/services/new", ""}
        ] do
      {:ok, view, _} = live(build_conn(), "/server/#{worker["id"]}/services/#{first["id"]}/edit")
      old_intent = socket(view).assigns.submission_id

      with_failure(fn ->
        render_patch(view, destination)
        assert has_element?(view, "#node-observation-error")
        refute has_element?(view, "#service-form")
        refute has_element?(view, "#node-workflow")
        assert socket(view).assigns.submission_id != old_intent
        assert socket(view).assigns.service == nil
        assert socket(view).assigns.preview == nil
        assert socket(view).assigns.target == nil
        assert Process.alive?(view.pid)
      end)

      render_click(view, "rotate_token", %{"_submission" => old_intent})
      render_click(view, "preview")

      render_submit(view, "save_service", %{
        "_submission" => old_intent,
        "service" => %{
          "id" => "dns",
          "listen_address" => "127.0.0.1",
          "port" => "5399",
          "desired_state" => "running"
        }
      })

      assert Domain.list_services(worker["id"]) == before
      assert Repo.aggregate(Audit, :count) == audit_count
      view |> element("#retry-node-load") |> render_click()
      assert has_element?(view, "#service-form input[name='service[id]'][value='#{expected_id}']")
      refute has_element?(view, "#node-observation-error")
    end
  end

  test "failed reload of the identical scope preserves dirty editor and preview", %{
    worker: worker
  } do
    {:ok, view, _} = live(build_conn(), "/server/#{worker["id"]}/dashboard")

    render_change(view, "validate_worker", %{
      "worker" => %{"name" => "Unsent edit", "profile_name" => "custom"}
    })

    original = socket(view)
    {:ok, target, _} = live(build_conn(), "/server/#{worker["id"]}/targets")
    render_click(target, "preview")
    original_target = socket(target)
    install_read_failure()

    with_failure(fn ->
      render_click(view, "reload")
      assert has_element?(view, "#node-observation-error")
      assert has_element?(view, "input[name='worker[name]'][value='Unsent edit']")
      assert socket(view).assigns.submission_id == original.assigns.submission_id
      assert socket(view).assigns.worker["revision"] == original.assigns.worker["revision"]
    end)

    with_failure(fn ->
      render_click(target, "reload")
      assert has_element?(target, "#node-observation-error")
      assert socket(target).assigns.preview == original_target.assigns.preview
      assert socket(target).assigns.submission_id == original_target.assigns.submission_id
    end)
  end

  test "failed list read retains enrollment edits and non-secret registration input", %{
    worker: worker
  } do
    {:ok, list, _} = live(build_conn(), "/management/servers")
    {:ok, policy, _} = live(build_conn(), "/management/servers/enrollment")

    render_change(policy, "validate_enrollment", %{"enrollment" => %{"allow_anonymous" => "true"}})

    install_read_failure()

    with_failure(fn ->
      send(list.pid, :refresh_workers)
      assert has_element?(list, "#nodes-observation-error")
      assert has_element?(list, "#server-selector-#{worker["id"]}")
    end)

    with_failure(fn ->
      send(policy.pid, :refresh_workers)
      assert has_element?(policy, "#nodes-observation-error")
      assert has_element?(policy, "input[type='checkbox'][checked]")
    end)

    send(policy.pid, :refresh_workers)
    refute has_element?(policy, "#nodes-observation-error")
    assert has_element?(policy, "input[type='checkbox'][checked]")
  end

  test "failure before token mutation retires the intent without retrying", %{worker: worker} do
    {:ok, view, _} = live(build_conn(), "/server/#{worker["id"]}/connection")
    before = Repo.get!(Worker, worker["id"]).connection_token_hash

    audit_count =
      Repo.aggregate(from(a in Audit, where: a.operation == "rotate_worker_token"), :count)

    intent = socket(view).assigns.submission_id
    install_read_failure()

    with_failure(fn ->
      render_click(view, "rotate_token", %{"_submission" => intent})
      assert render(view) =~ "Credential outcome is unknown"
      assert Process.alive?(view.pid)
      refute has_element?(view, "#worker-bootstrap")
    end)

    render_click(view, "rotate_token", %{"_submission" => intent})
    send(view.pid, :refresh_connection)
    assert Repo.get!(Worker, worker["id"]).connection_token_hash == before

    assert Repo.aggregate(from(a in Audit, where: a.operation == "rotate_worker_token"), :count) ==
             audit_count

    assert render(view) =~ "previous credential may no longer be valid"
    view |> element("button[phx-click='rotate_token']") |> render_click()
    assert has_element?(view, "#worker-bootstrap")

    assert Repo.aggregate(from(a in Audit, where: a.operation == "rotate_worker_token"), :count) ==
             audit_count + 1
  end

  test "ambiguous registration retains its generated identity, never chooses a same-name Worker" do
    {:ok, view, _} = live(build_conn(), "/management/servers")
    before = Repo.aggregate(Worker, :count)
    install_read_failure()
    intent = socket(view).assigns.submission_id

    with_failure(fn ->
      render_submit(view, "save", %{"worker" => %{"name" => "Same name"}, "_submission" => intent})

      assert render(view) =~ "Registration outcome is unknown"
      assert has_element?(view, "input[name='worker[name]'][value='Same name']")
      assert has_element?(view, "#worker-form button[disabled]")
      assert Process.alive?(view.pid)
    end)

    recovery_id = socket(view).assigns.credential_recovery
    assert is_binary(recovery_id)
    refute Enum.any?(Domain.list_workers(), &(&1["id"] == recovery_id))

    render_submit(view, "save", %{
      "worker" => %{"name" => "Same name"},
      "_submission" => socket(view).assigns.submission_id
    })

    send(view.pid, :refresh_workers)
    assert Repo.aggregate(Worker, :count) == before
    assert socket(view).assigns.credential_recovery == recovery_id
    render_click(view, "acknowledge_credential_outcome")
    view |> form("#worker-form", worker: %{name: "Same name"}) |> render_submit()
    assert Repo.aggregate(Worker, :count) == before + 1
    assert has_element?(view, "#worker-bootstrap")
  end

  test "lost acknowledgement after an actual committed issuance is uncertain, not replayed" do
    # Perform a real transaction, then model losing its acknowledgement at the operation boundary.
    before = Repo.aggregate(Worker, :count)

    assert {:error,
            %{code: "credential_outcome_unknown", details: %{"worker_id" => "recovery-id"}}} =
             Database.credential(
               fn ->
                 assert {:ok, _} = WorkerConnections.create("Acknowledgement lost")
                 raise DBConnection.ConnectionError, "commit response unavailable"
               end,
               "recovery-id"
             )

    assert Repo.aggregate(Worker, :count) == before + 1
    assert Enum.count(Domain.list_workers(), &(&1["name"] == "Acknowledgement lost")) == 1
  end

  test "dispatch does not hide PostgreSQL programming errors or persist a rejected receipt" do
    install_read_failure("42601")
    before_workers = Repo.aggregate(Worker, :count)
    before_audits = Repo.aggregate(Audit, :count)
    key = Ecto.UUID.generate()

    with_failure(fn ->
      assert_raise Postgrex.Error, fn ->
        Domain.mutate(
          "create_worker",
          %{"id" => Ecto.UUID.generate(), "name" => "Programming failure"},
          "operator",
          key
        )
      end
    end)

    assert Repo.aggregate(Worker, :count) == before_workers
    assert Repo.aggregate(Audit, :count) == before_audits
    refute Repo.get(YellowDog.Management.Idempotency, key)
  end

  defp socket(view), do: :sys.get_state(view.pid).socket

  defp install_read_failure(code \\ "08006") do
    role = "node_recovery_fault"
    Repo.query!("CREATE ROLE #{role}")
    Repo.query!("GRANT USAGE ON SCHEMA public TO #{role}")
    Repo.query!("GRANT ALL ON ALL TABLES IN SCHEMA public TO #{role}")
    Repo.query!("GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO #{role}")

    Repo.query!("""
    CREATE FUNCTION public.node_recovery_available() RETURNS boolean LANGUAGE plpgsql AS $$
    BEGIN
      IF current_setting('yellow_dog.test_outage', true) = 'on' THEN
        RAISE EXCEPTION 'Injected PostgreSQL failure' USING ERRCODE = '#{code}';
      END IF;
      RETURN true;
    END $$
    """)

    Repo.query!("ALTER TABLE management_workers ENABLE ROW LEVEL SECURITY")

    Repo.query!(
      "CREATE POLICY node_fault ON management_workers USING (public.node_recovery_available())"
    )
  end

  defp with_failure(fun) do
    Repo.query!("SET ROLE node_recovery_fault")
    Repo.query!("SET yellow_dog.test_outage = 'on'")

    try do
      fun.()
    after
      Repo.query!("SET yellow_dog.test_outage = 'off'")
      Repo.query!("RESET ROLE")
    end
  end
end
