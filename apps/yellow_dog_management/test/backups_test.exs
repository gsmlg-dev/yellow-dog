defmodule YellowDog.Management.BackupsTest do
  use ExUnit.Case, async: false
  alias YellowDog.Management.{Backup, Backups, Domain, Repo}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok
  end

  test "catalog reads expose no invented backups, audit or jobs" do
    assert Backups.list() == []
    assert Domain.list_audit() == []
    assert {:error, %{code: "invalid_request"}} = Backups.get("../file")
    assert {:error, %{code: "not_found"}} = Backups.get(Ecto.UUID.generate())
    assert {:error, %{code: "invalid_request"}} = Backups.verify(nil)
  end

  test "create is queued and atomically idempotent, without inventing a completed package" do
    assert {:ok, first} =
             Domain.mutate(
               "create_backup",
               %{"label" => "before changes"},
               "operator",
               "backup-once"
             )

    assert {:ok, ^first} =
             Domain.mutate(
               "create_backup",
               %{"label" => "before changes"},
               "operator",
               "backup-once"
             )

    assert first["state"] == "pending"
    assert is_nil(first["digest"])
    assert is_nil(first["completed_at"])
    assert [%{"id" => backup_id}] = Backups.list()
    assert backup_id == first["id"]
    backup = Repo.get!(Backup, backup_id)
    assert Repo.get!(Oban.Job, backup.job_id, prefix: "management_jobs").state == "available"
    assert length(Domain.list_audit()) == 1
    assert {:error, %{code: "busy"}} = command("delete_backup", %{"id" => backup_id})
    assert {:error, %{code: "not_ready"}} = Backups.verify(backup_id)
  end

  test "unknown fields, malformed identities and oversize labels cannot select filesystem paths" do
    for params <- [
          %{"label" => String.duplicate("a", 129)},
          %{"label" => []},
          %{"label" => "ok", "path" => "/tmp/file"}
        ] do
      assert {:error, %{code: "invalid_request"}} = command("create_backup", params)
    end

    assert {:error, %{code: "database_constraint"}} =
             command("create_backup", %{"label" => <<0>>})

    assert Backups.list() == []
    assert {:error, %{code: "invalid_request"}} = command("delete_backup", %{"id" => "../../tmp"})

    assert {:error, %{code: "not_found"}} =
             command("delete_backup", %{"id" => Ecto.UUID.generate()})
  end

  test "deletion only queues catalog-owned ready/failed packages and deduplicates requests" do
    backup =
      Repo.insert!(%Backup{
        label: "ready",
        state: "ready",
        digest: String.duplicate("a", 64),
        size: 10
      })

    assert {:ok, %{"state" => "deleting"}} =
             first = command("delete_backup", %{"id" => backup.id})

    assert ^first = command("delete_backup", %{"id" => backup.id})
    assert {:ok, %{"state" => "deleting"}} = Backups.get(backup.id)
    assert {:error, %{code: "not_ready"}} = Backups.verify(backup.id)
  end

  test "terminal queue failures never leave a forever-pending catalog presentation" do
    assert {:ok, created} = command("create_backup", %{"label" => "failed"})
    backup = Repo.get!(Backup, created["id"])

    Repo.get!(Oban.Job, backup.job_id, prefix: "management_jobs")
    |> Ecto.Changeset.change(state: "discarded", discarded_at: DateTime.utc_now())
    |> Repo.update!()

    assert {:ok, %{"state" => "failed"}} = Backups.get(backup.id)
    assert {:ok, %{"state" => "deleting"}} = command("delete_backup", %{"id" => backup.id})
  end

  defp command(operation, params),
    do: Domain.mutate(operation, params, "operator", Ecto.UUID.generate())
end
