defmodule YellowDog.Management.DataDatabaseRecoveryTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias YellowDog.Management.{Database, Domain, DomainFixtures, Idempotency, Repo, TaskArtifacts}
  alias YellowDog.ManagementUI.IpDatabaseLive

  @endpoint YellowDog.ManagementUI.Endpoint

  defmodule UnavailableRepo do
    use Ecto.Repo, otp_app: :yellow_dog_management, adapter: Ecto.Adapters.Postgres
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok = Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    unavailable =
      start_supervised!(
        {UnavailableRepo,
         name: nil,
         pool: DBConnection.ConnectionPool,
         pool_size: 1,
         hostname: "127.0.0.1",
         port: 0,
         username: "postgres",
         database: "unavailable",
         connect_timeout: 10,
         timeout: 50,
         queue_target: 1,
         queue_interval: 1}
      )

    %{conn: build_conn(), unavailable: unavailable}
  end

  test "notification and explicit reload outages preserve exact dirty schedules and recovery conflicts",
       context do
    {:ok, view, _} = live(context.conn, "/system/ip-database")

    render_change(view, "validate_schedule", %{
      "type" => "city",
      "task" => %{"enabled" => "true", "cron" => "15 3 * * *"}
    })

    before = socket(view).assigns
    use_repo(view, context.unavailable)
    send(view.pid, {:task_updated, "ip_city"})
    assert has_element?(view, "#ip-database-refresh-error", "last known")
    assert Process.alive?(view.pid)
    assert socket(view).assigns.schedules == before.schedules
    assert socket(view).assigns.sync_intents == before.sync_intents
    assert socket(view).assigns.databases == before.databases
    assert socket(view).assigns.checks == before.checks
    render_click(view, "reload_schedule", %{"type" => "city"})
    assert socket(view).assigns.schedules == before.schedules
    use_repo(view, Repo)
    send(view.pid, {:task_updated, "ip_city"})
    refute has_element?(view, "#ip-database-refresh-error")
    assert socket(view).assigns.schedules == before.schedules
    task = before.schedules["city"]

    assert {:ok, saved} =
             Domain.mutate(
               "update_task",
               %{
                 "key" => "ip_city",
                 "expected_revision" => task.revision,
                 "enabled" => false,
                 "cron" => "20 4 * * *"
               },
               "operator",
               Ecto.UUID.generate()
             )

    render_submit(view, "save_schedule", %{
      "type" => "city",
      "task" => task.form.params,
      "_submission" => task.token
    })

    assert has_element?(view, "#ip-database-error", "changed")
    assert socket(view).assigns.schedules["city"].revision == task.revision
    assert {:ok, ^saved} = Domain.get_task("ip_city")
  end

  test "known queued job survives postcommit display outage and original replay has one receipt and audit",
       context do
    {:ok, view, _} = live(context.conn, "/system/ip-database")
    intent = socket(view).assigns.sync_intents["city"]
    before = effects()
    fail_after_commit(view, context.unavailable)
    request = %{"type" => "city", "_submission" => intent.token}
    render_click(view, "download", request)
    assert_receive {:display_reads_unavailable, _pid}
    assert has_element?(view, "#ip-database-refresh-error")
    assert [job] = Domain.list_task_jobs("ip_city")
    assert has_element?(view, "#ip-database-download-result[data-job-id='#{job["id"]}']")
    refute has_element?(view, "#ip-database-error")

    assert {:ok, replayed} =
             Domain.mutate("run_task", %{"key" => "ip_city"}, "operator", intent.key)

    assert replayed == socket(view).assigns.download_result
    assert replayed["id"] == job["id"]
    render_click(view, "download", request)
    assert [^job] = Domain.list_task_jobs("ip_city")
    assert_one_effect(before, "run_task")
    use_repo(view, Repo)
  end

  test "saved schedule revision survives postcommit read outage and old submission cannot mutate twice",
       context do
    {:ok, view, _} = live(context.conn, "/system/ip-database")
    schedule = socket(view).assigns.schedules["city"]
    before = effects()
    fail_after_commit(view, context.unavailable)

    request = %{
      "type" => "city",
      "task" => %{"enabled" => "true", "cron" => "15 3 * * *"},
      "_submission" => schedule.token
    }

    render_submit(view, "save_schedule", request)
    assert_receive {:display_reads_unavailable, _pid}
    assert has_element?(view, "#ip-database-refresh-error")
    assert {:ok, saved} = Domain.get_task("ip_city")
    assert saved["revision"] == schedule.revision + 1
    assert socket(view).assigns.schedules["city"].revision == saved["revision"]

    assert has_element?(
             view,
             "#ip-database-settings-city",
             "Saved settings revision #{saved["revision"]}"
           )

    render_submit(view, "save_schedule", request)
    assert {:ok, ^saved} = Domain.get_task("ip_city")
    assert_one_effect(before, "update_task")
    use_repo(view, Repo)
  end

  test "unconfirmed synchronization retries the original committed key even after job completion",
       context do
    {:ok, view, _} = live(context.conn, "/system/ip-database")
    intent = socket(view).assigns.sync_intents["city"]
    request = %{"type" => "city", "_submission" => intent.token}
    use_repo(view, context.unavailable)
    render_click(view, "download", request)
    assert socket(view).assigns.sync_intents["city"] == %{intent | attempted: true}
    use_repo(view, Repo)

    assert {:ok, committed} =
             Domain.mutate("run_task", %{"key" => "ip_city"}, "operator", intent.key)

    Repo.get!(Styx.Job, committed["id"], prefix: "management_jobs")
    |> Ecto.Changeset.change(state: "completed", completed_at: DateTime.utc_now())
    |> Repo.update!(prefix: "management_jobs")

    before = effects()
    render_click(view, "download", request)
    assert [job] = Domain.list_task_jobs("ip_city")
    assert job["id"] == committed["id"]
    assert job["state"] == "completed"
    assert socket(view).assigns.download_result["id"] == committed["id"]
    assert effects() == before
  end

  test "unconfirmed schedule retry preserves request key and original revision", context do
    {:ok, view, _} = live(context.conn, "/system/ip-database")
    schedule = socket(view).assigns.schedules["city"]

    request = %{
      "type" => "city",
      "task" => %{"enabled" => "true", "cron" => "15 3 * * *"},
      "_submission" => schedule.token
    }

    use_repo(view, context.unavailable)
    render_submit(view, "save_schedule", request)
    pending = socket(view).assigns.schedules["city"]
    {payload, key} = pending.request
    render_submit(view, "save_schedule", request)
    assert socket(view).assigns.schedules["city"] == pending
    send(view.pid, {:task_updated, "ip_city"})
    assert has_element?(view, "#ip-database-refresh-error")
    assert socket(view).assigns.schedules["city"] == pending
    use_repo(view, Repo)
    # Model a lost acknowledgement: the server committed this exact pending request.
    assert {:ok, committed} = Domain.mutate("update_task", payload, "operator", key)
    before = effects()
    render_submit(view, "save_schedule", request)
    assert socket(view).assigns.schedules["city"].revision == committed["revision"]
    assert effects() == before
  end

  for {kind, segment, form_name, fields} <- [
        {"View", "views", "view",
         %{
           "name" => "saved-view",
           "priority" => "100",
           "enabled" => "true",
           "recursion_enabled" => "true",
           "ecs_enabled" => "false",
           "client_rules" => "allow any",
           "fallback_forwarders" => "",
           "fallback_timeout" => "2000",
           "fallback_retries" => "1"
         }},
        {"ACL", "acl", "acl",
         %{"name" => "saved-acl", "description" => "", "rules" => "allow any"}}
      ] do
    test "#{kind} postcommit reread outage retains committed identity and rejects duplicate submission",
         context do
      kind = unquote(kind)
      worker = mutate("create_worker", %{"id" => "data-recovery", "name" => "Recovery"})

      service =
        mutate("put_service", DomainFixtures.service(worker["id"], worker["revision"], "stopped"))

      {:ok, view, _} =
        live(context.conn, "/server/#{worker["id"]}/dns/#{unquote(segment)}/#{service["id"]}")

      render_change(view, "validate", %{unquote(form_name) => unquote(Macro.escape(fields))})
      original = socket(view).assigns
      use_repo(view, context.unavailable)
      render_click(view, "refresh")
      retained = socket(view).assigns

      for key <- [:form, :editing, :dirty, :editor_reset, :submission_id, :submissions] do
        assert retained[key] == original[key]
      end

      assert retained.refresh_error
      use_repo(view, Repo)
      token = socket(view).assigns.submission_id
      request = %{unquote(form_name) => unquote(Macro.escape(fields)), "_submission" => token}
      before = effects()
      fail_after_commit(view, context.unavailable)
      render_submit(view, "save", request)
      assert_receive {:display_reads_unavailable, _pid}
      assert Process.alive?(view.pid)
      assert render(view) =~ "#{kind} saved"
      assert render(view) =~ "refresh"
      assert socket(view).assigns.editing["id"]
      assert socket(view).assigns.editing["revision"] == 1
      render_submit(view, "save", request)
      assert_one_effect(before, "create_dns_#{if kind == "View", do: "view", else: "acl"}")
      use_repo(view, Repo)
    end
  end

  for {module, segment} <- [
        {YellowDog.ManagementUI.DnsViewsLive, "views"},
        {YellowDog.ManagementUI.DnsAclsLive, "acl"}
      ] do
    test "#{module} renders and recovers after its first scoped read is unavailable", context do
      module = unquote(module)
      worker = mutate("create_worker", %{"id" => "initial-read-recovery", "name" => "Recovery"})

      service =
        mutate("put_service", DomainFixtures.service(worker["id"], worker["revision"], "stopped"))

      path = "/server/#{worker["id"]}/dns/#{unquote(segment)}/#{service["id"]}"

      base = %Phoenix.LiveView.Socket{
        router: YellowDog.ManagementUI.Router,
        assigns: %{__changed__: %{}, flash: %{}, current_path: path}
      }

      assert {:ok, mounted} = module.mount(%{}, %{}, base)
      previous = Repo.get_dynamic_repo()

      failed =
        try do
          Repo.put_dynamic_repo(context.unavailable)

          assert {:noreply, failed} =
                   module.handle_params(%{}, "http://localhost" <> path, mounted)

          failed
        after
          Repo.put_dynamic_repo(previous)
        end

      assert render_component(&module.render/1, failed.assigns) =~ "Data refresh unavailable"
      assert is_binary(failed.assigns.row_submission_id)
      assert failed.assigns.scope_params["server_id"] == worker["id"]
      assert {:noreply, recovered} = module.handle_event("refresh", %{}, failed)
      assert recovered.assigns.refresh_error == nil
      assert recovered.assigns.worker["id"] == worker["id"]
      assert recovered.assigns.service["id"] == service["id"]
      refute render_component(&module.render/1, recovered.assigns) =~ "Data refresh unavailable"
    end
  end

  test "initial read outage has a recoverable unavailable state", context do
    previous = Repo.get_dynamic_repo()

    failed =
      try do
        Repo.put_dynamic_repo(context.unavailable)
        assert {:ok, failed} = IpDatabaseLive.mount(%{}, %{}, %Phoenix.LiveView.Socket{})
        failed
      after
        Repo.put_dynamic_repo(previous)
      end

    assert failed.assigns.refresh_error =~ "refresh unavailable"
    assert failed.assigns.schedules == %{}
    assert {:noreply, recovered} = IpDatabaseLive.handle_event("refresh", %{}, failed)
    assert recovered.assigns.refresh_error == nil
    assert map_size(recovered.assigns.schedules) == 2
  end

  test "artifact infrastructure failure leaves byte validity unknown", context do
    {:ok, view, _} = live(context.conn, "/system/ip-database")
    token = make_ref()
    identity = {String.duplicate("a", 64), nil, nil, nil}
    selected = %{digest: elem(identity, 0), selected_at: nil, job_id: nil, attempt: nil}

    check = %{
      token: token,
      identity: identity,
      state: :checking,
      available: nil,
      availability_error: nil,
      checked_at: nil
    }

    socket = socket(view)
    database = %{hd(socket.assigns.databases) | selected: selected}
    socket = Phoenix.Component.assign(socket, databases: [database], checks: %{"city" => check})
    previous = Repo.get_dynamic_repo()

    outcome =
      try do
        Repo.put_dynamic_repo(context.unavailable)
        Database.read(fn -> TaskArtifacts.get("city", selected.digest) end)
      after
        Repo.put_dynamic_repo(previous)
      end

    assert {:noreply, unavailable} =
             IpDatabaseLive.handle_async({:artifact_check, "city", token}, {:ok, outcome}, socket)

    assert unavailable.assigns.checks["city"].state == :unavailable
    assert unavailable.assigns.checks["city"].available == nil
    assert hd(unavailable.assigns.databases).selected.digest == selected.digest
    assert hd(unavailable.assigns.databases).selected.verification == :unavailable

    assert {:noreply, ^unavailable} =
             IpDatabaseLive.handle_async(
               {:artifact_check, "city", make_ref()},
               {:ok, {:ok, {:ok, %{}}}},
               unavailable
             )
  end

  test "unexpected query and programming errors propagate through the read boundary" do
    assert_raise Postgrex.Error, fn ->
      Database.read(fn -> Repo.query!("SELECT * FROM missing_data_recovery_table") end)
    end

    assert_raise ArgumentError, fn ->
      Database.read(fn -> raise ArgumentError, "unexpected" end)
    end

    assert {:error, %{code: "database_unavailable"}} =
             Database.read(fn -> raise DBConnection.ConnectionError, "unavailable" end)
  end

  defp socket(view), do: :sys.get_state(view.pid).socket

  defp use_repo(view, repo) do
    :sys.replace_state(view.pid, fn state ->
      Repo.put_dynamic_repo(repo)
      state
    end)
  end

  defp fail_after_commit(view, unavailable) do
    handler = "data-read-fault-#{Ecto.UUID.generate()}"

    :ok =
      :telemetry.attach(
        handler,
        [:yellow_dog, :management, :repo, :query],
        &__MODULE__.after_commit/4,
        {view.pid, unavailable, self(), handler}
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  def after_commit(_event, _measurements, metadata, {pid, unavailable, owner, handler}) do
    if self() == pid and String.downcase(metadata.query) == "commit" do
      :telemetry.detach(handler)
      Repo.put_dynamic_repo(unavailable)
      send(owner, {:display_reads_unavailable, self()})
    end
  end

  defp mutate(operation, params) do
    assert {:ok, result} = Domain.mutate(operation, params, "operator", Ecto.UUID.generate())
    result
  end

  defp effects, do: {Repo.all(Idempotency), Domain.list_audit()}

  defp assert_one_effect({receipts, audits}, operation) do
    assert [_receipt] = Repo.all(Idempotency) -- receipts
    assert [audit] = Domain.list_audit() -- audits
    assert audit["operation"] == operation
  end
end
