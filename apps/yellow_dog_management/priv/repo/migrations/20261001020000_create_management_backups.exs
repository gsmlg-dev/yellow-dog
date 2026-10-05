defmodule YellowDog.Management.Repo.Migrations.CreateManagementBackups do
  use Ecto.Migration

  def change do
    create table(:management_backups, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :label, :string, null: false, default: ""
      add :state, :string, null: false, default: "pending"

      add :job_id,
          references(:oban_jobs, prefix: "management_jobs", type: :bigint, on_delete: :restrict)

      add :manifest, :map
      add :digest, :string
      add :size, :bigint
      add :row_count, :bigint
      add :completed_at, :utc_datetime_usec
      add :error, :text
      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:management_backups, :management_backup_state,
             check: "state IN ('pending', 'ready', 'deleting', 'deleted', 'failed')"
           )
  end
end
