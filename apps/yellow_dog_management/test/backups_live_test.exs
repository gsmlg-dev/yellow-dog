defmodule YellowDog.Management.BackupsLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias YellowDog.Management.{Backup, BackupFiles, Backups, Domain, PostgresTools, Repo}
  alias YellowDog.ManagementUI.BackupsLive

  @endpoint YellowDog.ManagementUI.Endpoint

  setup tags do
    if tags[:unboxed] do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)
      on_exit(fn -> Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual) end)
    else
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
      Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    end

    previous = System.get_env("YELLOW_DOG_MANAGEMENT_BACKUP_DIRECTORY")
    directory = Path.join(System.tmp_dir!(), "backups-ui-#{Ecto.UUID.generate()}")
    File.mkdir_p!(directory)
    System.put_env("YELLOW_DOG_MANAGEMENT_BACKUP_DIRECTORY", directory)

    on_exit(fn ->
      if previous,
        do: System.put_env("YELLOW_DOG_MANAGEMENT_BACKUP_DIRECTORY", previous),
        else: System.delete_env("YELLOW_DOG_MANAGEMENT_BACKUP_DIRECTORY")

      File.rm_rf!(directory)
    end)

    %{conn: build_conn()}
  end

  test "index and restore are read-only and do not require login", %{conn: conn} do
    before_visit = snapshot()
    {:ok, index, html} = live(conn, "/system/backups")
    assert has_element?(index, "#backups-page")
    assert has_element?(index, "#backup-create-form input[maxlength='128']")
    refute html =~ "type=\"password\""
    render_click(index, "refresh", %{})

    {:ok, restore, html} = live(conn, "/system/backups/restore?id=forged")
    assert has_element?(restore, "#backup-restore-page")
    assert html =~ "downtime"
    assert html =~ "offline"
    assert has_element?(restore, "#backup-restore-capability", "not available yet")
    refute has_element?(restore, "#backup-restore-command")
    render_click(restore, "refresh", %{})
    assert snapshot() == before_visit
  end

  test "malformed or overlong labels fail before any mutation", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/system/backups")
    before_submit = snapshot()

    for label <- [
          String.duplicate("x", 129),
          String.duplicate("é", 65),
          <<0>>,
          %{},
          ["label"],
          nil
        ] do
      render_click(view, "create_backup", %{"label" => label})
      assert has_element?(view, "#backup-error", "128")
      assert snapshot() == before_submit
      assert Process.alive?(view.pid)
    end
  end

  test "invalid and forged action identities fail closed without writes", %{conn: conn} do
    {:ok, index, _html} = live(conn, "/system/backups")
    {:ok, restore, _html} = live(conn, "/system/backups/restore")
    before_actions = snapshot()

    for id <- ["missing", "../other", %{"id" => "other"}, ["other"], nil] do
      for event <- ["verify", "delete", "confirm_delete"] do
        render_click(index, event, %{"id" => id})
        assert has_element?(index, "#backup-error")
      end

      render_click(restore, "select_restore", %{"id" => id})
      render_click(restore, "confirm_restore", %{"id" => id})
      refute has_element?(restore, "#backup-restore-command")
      assert snapshot() == before_actions
    end
  end

  test "restore confirmation never accepts client supplied verification" do
    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        live_action: :restore,
        restore_backup: nil,
        verification: nil,
        restore_confirmed: false
      }
    }

    assert {:noreply, result} =
             BackupsLive.handle_event(
               "confirm_restore",
               %{"id" => Ecto.UUID.generate(), "valid" => true},
               socket
             )

    assert result.assigns.error =~ "verified"
    refute result.assigns.restore_confirmed
  end

  test "queued creation resets controls without claiming completion", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/system/backups")
    label = "Before maintenance <script>"
    view |> form("#backup-create-form", label: label) |> render_submit()
    [backup] = Backups.list()
    assert value(backup, :label) == label
    assert value(backup, :state) == "pending"
    assert has_element?(view, "#backup-label[value='']")
    assert has_element?(view, "#backup-notice", "Pending is not successful completion")
    assert has_element?(view, "#backup-row-#{value(backup, :id)}", label)
    assert render(view) =~ "&lt;script&gt;"
    refute has_element?(view, "#backups-list script")
    assert Repo.aggregate(Oban.Job, :count, prefix: "management_jobs") == 1
    assert :sys.get_state(view.pid).socket.assigns.poll_timer != nil
  end

  test "all persisted metadata and failures are visible without writes", %{conn: conn} do
    backup =
      fixture("failed",
        label: "Failure <script>",
        digest: String.duplicate("a", 64),
        size: 1234,
        row_count: 12,
        completed_at: DateTime.utc_now(),
        error: "Disk is full <script>"
      )

    before_visit = snapshot()
    {:ok, view, html} = live(conn, "/system/backups")
    assert has_element?(view, "#backup-row-#{backup.id}", "Failure <script>")
    assert html =~ "1234"
    assert html =~ backup.digest
    assert html =~ "Disk is full &lt;script&gt;"
    assert html =~ "Check service logs and retry"
    assert html =~ DateTime.to_iso8601(backup.inserted_at)
    assert html =~ DateTime.to_iso8601(backup.completed_at)
    refute has_element?(view, "a[href='/api/backups/#{backup.id}/download']")
    assert snapshot() == before_visit
  end

  test "deletion requires server selection, cancellation and matching confirmation", %{conn: conn} do
    first = fixture("failed", label: "First")
    second = fixture("failed", label: "Second")
    {:ok, view, _html} = live(conn, "/system/backups")
    before_delete = snapshot()
    render_click(view, "confirm_delete", %{"id" => first.id})
    assert snapshot() == before_delete
    render_click(view, "delete", %{"id" => first.id})
    assert has_element?(view, "#backup-delete-confirmation", first.id)
    assert snapshot() == before_delete
    render_click(view, "cancel_delete", %{})
    refute has_element?(view, "#backup-delete-confirmation")
    render_click(view, "confirm_delete", %{"id" => first.id})
    assert snapshot() == before_delete

    render_click(view, "delete", %{"id" => first.id})
    render_click(view, "confirm_delete", %{"id" => second.id})
    assert has_element?(view, "#backup-error", "does not match")
    assert snapshot() == before_delete
    view |> element("#backup-confirm-delete") |> render_click()
    refute has_element?(view, "#backup-delete-confirmation")
    assert {:ok, deleting} = Backups.get(first.id)
    assert value(deleting, :state) == "deleting"
    assert {:ok, untouched} = Backups.get(second.id)
    assert value(untouched, :state) == "failed"
    assert has_element?(view, "#backup-notice", "Deletion queued")
    assert :sys.get_state(view.pid).socket.assigns.poll_timer != nil
  end

  test "pending and deleting states poll to terminal outcomes without broadcasts or writes", %{
    conn: conn
  } do
    pending = fixture("pending")
    deleting = fixture("deleting")
    {:ok, view, _html} = live(conn, "/system/backups")
    assert :sys.get_state(view.pid).socket.assigns.poll_timer != nil
    pending |> Ecto.Changeset.change(state: "failed", error: "Capture failed") |> Repo.update!()
    deleting |> Ecto.Changeset.change(state: "deleted") |> Repo.update!()
    before_poll = snapshot()

    assert eventually(fn ->
             has_element?(view, "#backups-list", "Capture failed") and
               has_element?(view, "#backups-list", "deleted")
           end)

    assert :sys.get_state(view.pid).socket.assigns.poll_timer == nil
    assert snapshot() == before_poll
  end

  test "PubSub refresh observes package failure without writing", %{conn: conn} do
    backup = fixture("pending")
    {:ok, view, _html} = live(conn, "/system/backups")

    backup
    |> Ecto.Changeset.change(state: "failed", error: "Capture interrupted")
    |> Repo.update!()

    before_update = snapshot()

    Phoenix.PubSub.broadcast(
      YellowDog.ManagementUI.PubSub,
      "management:backups",
      {:backup_updated, backup.id}
    )

    assert render(view) =~ "Capture interrupted"
    assert :sys.get_state(view.pid).socket.assigns.poll_timer == nil
    assert snapshot() == before_update
  end

  test "real verification rejects a missing package asynchronously and remains dismissible", %{
    conn: conn
  } do
    backup = fixture("ready", digest: String.duplicate("b", 64))
    {:ok, view, _html} = live(conn, "/system/backups")
    before_verify = snapshot()
    html = render_click(view, "verify", %{"id" => backup.id})
    assert html =~ "Verifying checksums and package contents"
    render_async(view)
    assert has_element?(view, "#backup-error", "Verification failed")
    refute has_element?(view, "#backup-verification")
    refute has_element?(view, "#backup-verifying")
    assert snapshot() == before_verify
    render_click(view, "dismiss_verify", %{})
    refute has_element?(view, "#backup-error")
    assert Process.alive?(view.pid)

    {:ok, restore, _html} = live(conn, "/system/backups/restore")
    render_submit(restore, "select_restore", %{"id" => backup.id})
    render_async(restore)
    assert has_element?(restore, "#backup-error", "Verification failed")
    render_click(restore, "confirm_restore", %{"id" => backup.id, "valid" => true})
    refute has_element?(restore, "#backup-restore-command")
    render_click(restore, "cancel_restore", %{})
    assert snapshot() == before_verify
  end

  @tag :unboxed
  test "real verified package is dismissible and download uses the current API route", %{
    conn: conn
  } do
    backup = ready_package(true)
    assert {:ok, result} = Backups.verify(backup.id)
    assert value(result, :valid) == true
    before_verify = snapshot()
    {:ok, view, _html} = live(conn, "/system/backups")
    assert has_element?(view, "a[href='/api/backups/#{backup.id}/download']", "Download")
    html = render_click(view, "verify", %{"id" => backup.id})
    assert html =~ "Verifying checksums and package contents"
    render_async(view)
    assert has_element?(view, "#backup-verification[data-backup-id='#{backup.id}']")
    assert has_element?(view, "#backup-verification", value(result, :dump_digest))
    assert has_element?(view, "#backup-verification", "byte_integrity")
    assert has_element?(view, "#backup-verification", "does not prove full recoverability")
    refute has_element?(view, "#backup-verifying")
    refute has_element?(view, "#backup-error")
    render_click(view, "dismiss_verify", %{})
    refute has_element?(view, "#backup-verification")

    render_click(view, "verify", %{"id" => backup.id})
    render_click(view, "dismiss_verify", %{})
    render_async(view)
    refute has_element?(view, "#backup-verification")
    assert snapshot() == before_verify
  end

  test "offline restore acknowledgement requires verification and never offers an unimplemented CLI",
       %{
         conn: conn
       } do
    backup = ready_package()
    {:ok, view, _html} = live(conn, "/system/backups/restore")
    before_restore = snapshot()
    view |> form("#backup-restore-form", id: backup.id) |> render_submit()
    render_async(view)
    assert has_element?(view, "#backup-verification[data-backup-id='#{backup.id}']")
    refute has_element?(view, "#backup-restore-command")
    render_click(view, "confirm_restore", %{"id" => Ecto.UUID.generate()})
    refute has_element?(view, "#backup-restore-command")
    refute has_element?(view, "#backup-restore-unavailable")
    view |> element("#backup-confirm-restore") |> render_click()
    assert has_element?(view, "#backup-restore-unavailable", backup.id)
    assert has_element?(view, "#backup-restore-unavailable", "not available yet")
    assert has_element?(view, "#backup-restore-unavailable", "No restore has run from this page")
    refute render(view) =~ "mix management.restore"
    render_click(view, "cancel_restore", %{})
    refute has_element?(view, "#backup-verification")
    refute has_element?(view, "#backup-restore-command")
    refute has_element?(view, "#backup-restore-unavailable")
    render_click(view, "confirm_restore", %{"id" => backup.id, "valid" => true})
    refute has_element?(view, "#backup-restore-command")
    render_submit(view, "create_backup", %{"label" => "forged"})
    render_click(view, "delete", %{"id" => backup.id})
    render_click(view, "confirm_delete", %{"id" => backup.id})
    assert snapshot() == before_restore
  end

  test "corrupt dump fails real checksums and cannot prepare a restore", %{conn: conn} do
    backup = ready_package()
    dump = Path.join(BackupFiles.directory(backup.id), "database.dump")
    File.chmod!(dump, 0o600)
    File.write!(dump, "corrupt dump")
    assert {:error, _error} = Backups.verify(backup.id)
    before_verify = snapshot()
    {:ok, view, _html} = live(conn, "/system/backups/restore")
    render_submit(view, "select_restore", %{"id" => backup.id})
    render_async(view)
    assert has_element?(view, "#backup-error", "Verification failed")
    refute has_element?(view, "#backup-verification")
    render_click(view, "confirm_restore", %{"id" => backup.id, "valid" => true})
    refute has_element?(view, "#backup-restore-command")
    assert snapshot() == before_verify
  end

  test "verified acknowledgements are invalidated when the package becomes unavailable", %{
    conn: conn
  } do
    backup = ready_package()
    {:ok, view, _html} = live(conn, "/system/backups/restore")
    render_submit(view, "select_restore", %{"id" => backup.id})
    render_async(view)
    render_click(view, "confirm_restore", %{"id" => backup.id})
    assert has_element?(view, "#backup-restore-unavailable")
    backup |> Ecto.Changeset.change(state: "deleting") |> Repo.update!()
    before_refresh = snapshot()
    render_click(view, "refresh", %{})
    refute has_element?(view, "#backup-verification")
    refute has_element?(view, "#backup-restore-command")
    refute has_element?(view, "#backup-restore-unavailable")
    render_click(view, "confirm_restore", %{"id" => backup.id})
    refute has_element?(view, "#backup-restore-command")
    assert snapshot() == before_refresh
  end

  defp ready_package(unboxed \\ false) do
    backup = fixture("pending")
    directory = BackupFiles.directory(backup.id)
    File.mkdir_p!(directory)
    dump = Path.join(directory, "database.dump")

    assert {:ok, _output} =
             PostgresTools.run("pg_dump", ["--format=custom", "--file", dump],
               env:
                 PostgresTools.connection_env(
                   System.fetch_env!("YELLOW_DOG_MANAGEMENT_DATABASE_URL")
                 )
             )

    assert {:ok, dump_info} = BackupFiles.hash(dump)

    manifest = %{
      "format" => BackupFiles.manifest_format(),
      "id" => backup.id,
      "dump" => %{
        "path" => "database.dump",
        "digest" => dump_info.digest,
        "size" => dump_info.size
      },
      "artifacts" => [],
      "row_count" => 0
    }

    assert {:ok, archive} = BackupFiles.seal(directory, manifest)

    backup =
      backup
      |> Ecto.Changeset.change(
        state: "ready",
        manifest: manifest,
        digest: archive.digest,
        size: archive.size,
        row_count: 0,
        completed_at: DateTime.utc_now()
      )
      |> Repo.update!()

    if unboxed, do: on_exit(fn -> Repo.delete!(backup) end)
    backup
  end

  defp fixture(state, attributes \\ []) do
    struct!(Backup, Keyword.merge([state: state, label: "Fixture"], attributes))
    |> Repo.insert!()
  end

  defp value(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp eventually(predicate, attempts \\ 60)
  defp eventually(_predicate, 0), do: false

  defp eventually(predicate, attempts) do
    if predicate.() do
      true
    else
      Process.sleep(50)
      eventually(predicate, attempts - 1)
    end
  end

  defp snapshot do
    {Backups.list(), Domain.list_audit(), Repo.all(Oban.Job, prefix: "management_jobs")}
  end
end
