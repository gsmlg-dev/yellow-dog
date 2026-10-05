defmodule YellowDog.Management.Backups do
  import Ecto.Query

  alias YellowDog.Management.{
    Backup,
    BackupFiles,
    BackupWorker,
    GeoIPArtifact,
    PostgresTools,
    Repo,
    Settings
  }

  def list,
    do:
      Repo.all(from(backup in Backup, order_by: [desc: backup.inserted_at]))
      |> Enum.map(&backup_map/1)

  def get(id) do
    with {:ok, id} <- uuid(id) do
      case Repo.get(Backup, id) do
        nil -> {:error, error("not_found", "Backup not found")}
        backup -> {:ok, backup_map(backup)}
      end
    end
  end

  def dispatch("create_backup", params) do
    allowed!(params, ~w(label))
    label = Map.get(params, "label", "")

    unless is_binary(label) and String.valid?(label) and byte_size(label) <= 128 and
             not String.contains?(label, <<0>>),
           do: abort("invalid_request", "Label must be text up to 128 bytes")

    backup = Repo.insert!(%Backup{label: label})

    {:ok, job} =
      BackupWorker.new(%{"backup_id" => backup.id, "operation" => "create"}) |> Oban.insert()

    backup |> Ecto.Changeset.change(job_id: job.id) |> Repo.update!() |> backup_map()
  end

  def dispatch("delete_backup", params) do
    allowed!(params, ~w(id))
    backup = lock!(params["id"])

    case effective_state(backup) do
      state when state in ~w(deleted deleting) ->
        backup_map(backup)

      state when state in ~w(ready failed) ->
        {:ok, job} =
          BackupWorker.new(%{"backup_id" => backup.id, "operation" => "delete"}) |> Oban.insert()

        backup
        |> Ecto.Changeset.change(state: "deleting", job_id: job.id, error: nil)
        |> Repo.update!()
        |> backup_map()

      _pending ->
        abort("busy", "A backup in progress cannot be deleted")
    end
  end

  def verify(id),
    do:
      with_ready(id, fn backup ->
        case BackupFiles.verify(backup.id, backup.manifest, backup.digest) do
          {:ok, result} ->
            {:ok, result}

          {:error, _reason} ->
            {:error,
             error("backup_integrity", "Package integrity check failed; not safe to restore")}
        end
      end)

  def download(id, send_file) when is_function(send_file, 1),
    do:
      with_ready(id, fn backup ->
        case BackupFiles.hash(Path.join(BackupFiles.directory(backup.id), "package.tar")) do
          {:ok, %{digest: digest}} when digest == backup.digest ->
            send_file.(Path.join(BackupFiles.directory(backup.id), "package.tar"))

          _error ->
            {:error, error("backup_integrity", "Backup archive is missing or corrupt")}
        end
      end)

  def perform(job, "create", id) do
    backup = Repo.get!(Backup, id)

    if backup.state == "ready" do
      case verify(id) do
        {:ok, _proof} -> :ok
        error -> error
      end
    else
      create_package(job, backup)
    end
  end

  def perform(job, "delete", id) do
    transaction =
      Repo.transaction(fn ->
        claim!(job)
        backup = lock!(id)

        if backup.state == "deleted" do
          :ok
        else
          unless backup.job_id == job.id and backup.state == "deleting",
            do: Repo.rollback(:stale_backup_job)

          case File.rm_rf(BackupFiles.directory(id)) do
            {:ok, []} -> :ok
            {:ok, _paths} -> :ok = BackupFiles.sync_directory(Settings.backup_directory())
            {:error, _reason, _path} -> Repo.rollback(:backup_delete_failed)
          end

          backup |> Ecto.Changeset.change(state: "deleted", error: nil) |> Repo.update!()
          :ok
        end
      end)

    case transaction do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def record_error(job, reason) do
    id = job.args["backup_id"]

    Repo.transaction(fn ->
      backup = lock!(id)

      if backup.job_id == job.id and backup.state in ~w(pending deleting) do
        backup
        |> Ecto.Changeset.change(
          error: inspect(reason, limit: 10, printable_limit: 200),
          state: if(job.attempt >= job.max_attempts, do: "failed", else: backup.state)
        )
        |> Repo.update!()
      end
    end)
  end

  def broadcast(id),
    do:
      Phoenix.PubSub.broadcast(
        YellowDog.ManagementUI.PubSub,
        "management:backups",
        {:backup_updated, id}
      )

  defp create_package(job, backup) do
    root = Settings.backup_directory()
    staging = Path.join(root, ".staging-#{backup.id}-#{Ecto.UUID.generate()}")
    File.mkdir_p!(root)
    unless File.lstat!(root).type == :directory, do: raise("Backup root must be a real directory")
    File.chmod!(root, 0o700)
    File.mkdir!(staging)

    try do
      capture =
        case File.lstat(BackupFiles.directory(backup.id)) do
          {:error, :enoent} ->
            with {:ok, manifest} <- capture(staging, backup, job),
                 {:ok, archive} <- BackupFiles.seal(staging, manifest),
                 do: {:ok, manifest, archive, false}

          {:ok, _stat} ->
            with {:ok, manifest, archive} <- BackupFiles.recover(backup.id, job.id, backup.label),
                 do: {:ok, manifest, archive, true}

          {:error, reason} ->
            {:error, reason}
        end

      with {:ok, manifest, archive, published} <- capture do
        case Repo.transaction(fn ->
               claim!(job)
               current = lock!(backup.id)

               unless current.job_id == job.id and current.state == "pending",
                 do: Repo.rollback(:stale_backup_job)

               case if(published,
                      do: BackupFiles.sync_directory(root),
                      else: BackupFiles.publish(staging, backup.id)
                    ) do
                 :ok -> :ok
                 {:error, reason} -> Repo.rollback(reason)
               end

               current
               |> Ecto.Changeset.change(
                 state: "ready",
                 manifest: manifest,
                 digest: archive.digest,
                 size: archive.size,
                 row_count: manifest["row_count"],
                 completed_at: DateTime.utc_now(),
                 error: nil
               )
               |> Repo.update!()
             end) do
          {:ok, _backup} -> :ok
          {:error, reason} -> {:error, reason}
        end
      end
    after
      File.rm_rf(staging)
    end
  end

  defp capture(staging, backup, job) do
    Repo.transaction(
      fn ->
        Repo.query!("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY")
        %{rows: [[snapshot]]} = Repo.query!("SELECT pg_export_snapshot()")

        %{rows: tables} =
          Repo.query!(
            "SELECT schemaname, tablename FROM pg_tables WHERE schemaname IN ('public','management_jobs') ORDER BY schemaname, tablename"
          )

        counts =
          Map.new(tables, fn [schema, table] ->
            quoted_schema = String.replace(schema, "\"", "\"\"")
            quoted_table = String.replace(table, "\"", "\"\"")

            %{rows: [[count]]} =
              Repo.query!("SELECT count(*) FROM \"#{quoted_schema}\".\"#{quoted_table}\"")

            {"#{schema}.#{table}", count}
          end)

        env =
          PostgresTools.connection_env(System.fetch_env!("YELLOW_DOG_MANAGEMENT_DATABASE_URL"))

        case PostgresTools.run(
               "pg_dump",
               [
                 "--format=custom",
                 "--no-owner",
                 "--no-privileges",
                 "--snapshot=#{snapshot}",
                 "--file",
                 Path.join(staging, "database.dump")
               ],
               env: env
             ) do
          {:ok, _output} -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end

        {:ok, dump} = BackupFiles.hash(Path.join(staging, "database.dump"))

        artifacts =
          Repo.all(GeoIPArtifact)
          |> Enum.map(fn artifact ->
            case BackupFiles.copy_artifact(artifact, staging) do
              {:ok, item} -> item
              {:error, reason} -> Repo.rollback(reason)
            end
          end)

        %{
          "format" => BackupFiles.manifest_format(),
          "id" => backup.id,
          "label" => backup.label,
          "creating_job_id" => job.id,
          "captured_at" => DateTime.to_iso8601(DateTime.utc_now()),
          "snapshot" => snapshot,
          "artifact_root" => Settings.artifact_directory(),
          "dump" =>
            Map.merge(%{"path" => "database.dump"}, %{
              "digest" => dump.digest,
              "size" => dump.size
            }),
          "artifacts" => artifacts,
          "tables" => counts,
          "row_count" => counts |> Map.values() |> Enum.sum(),
          "exclusions" => [
            "Worker local state",
            "Logger/ETS/socket/process state",
            "deployment credentials",
            "other backup package files"
          ],
          "capture_boundary" =>
            "Snapshot precedes this backup job's completion and ready catalog receipt"
        }
      end,
      timeout: 180_000
    )
  end

  defp with_ready(id, action) do
    with {:ok, id} <- uuid(id) do
      case Repo.transaction(
             fn ->
               case Repo.one(from(backup in Backup, where: backup.id == ^id, lock: "FOR SHARE")) do
                 nil -> {:error, error("not_found", "Backup not found")}
                 %{state: "ready"} = backup -> action.(backup)
                 _backup -> {:error, error("not_ready", "Backup is not ready")}
               end
             end,
             timeout: 180_000
           ) do
        {:ok, result} -> result
        {:error, _reason} -> {:error, error("backup_unavailable", "Backup operation failed")}
      end
    end
  end

  defp claim!(job) do
    claim =
      Repo.one!(
        from(queued in Oban.Job,
          prefix: "management_jobs",
          where: queued.id == ^job.id,
          lock: "FOR UPDATE"
        )
      )

    unless claim.state == "executing" and claim.attempt == job.attempt,
      do: Repo.rollback(:stale_backup_job)
  end

  defp lock!(id) do
    case uuid(id) do
      {:ok, id} ->
        Repo.one(from(backup in Backup, where: backup.id == ^id, lock: "FOR UPDATE")) ||
          abort("not_found", "Backup not found")

      {:error, failure} ->
        throw({:management_abort, failure})
    end
  end

  defp effective_state(backup) do
    job = if backup.job_id, do: Repo.get(Oban.Job, backup.job_id, prefix: "management_jobs")
    effective_state(backup, job)
  end

  defp effective_state(backup, job) do
    if backup.state in ~w(pending deleting) and not is_nil(job) and
         job.state in ~w(discarded cancelled),
       do: "failed",
       else: backup.state
  end

  defp backup_map(backup) do
    job = if backup.job_id, do: Repo.get(Oban.Job, backup.job_id, prefix: "management_jobs")
    last_error = if job, do: List.last(job.errors || [])

    %{
      "id" => backup.id,
      "label" => backup.label,
      "state" => effective_state(backup, job),
      "created_at" => DateTime.to_iso8601(backup.inserted_at),
      "completed_at" => if(backup.completed_at, do: DateTime.to_iso8601(backup.completed_at)),
      "size" => backup.size,
      "digest" => backup.digest,
      "row_count" => backup.row_count,
      "error" =>
        backup.error || if(last_error, do: String.slice(last_error["error"] || "", 0, 1024))
    }
  end

  defp uuid(id) when is_binary(id) and byte_size(id) == 36 do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, error("invalid_request", "Backup ID must be a UUID")}
    end
  end

  defp uuid(_id), do: {:error, error("invalid_request", "Backup ID must be a UUID")}

  defp allowed!(params, keys),
    do:
      if(Enum.any?(Map.keys(params), &(&1 not in keys)),
        do: abort("invalid_request", "Unsupported backup field")
      )

  defp abort(code, message), do: throw({:management_abort, error(code, message)})
  defp error(code, message), do: %{code: code, message: message, details: %{}}
end
