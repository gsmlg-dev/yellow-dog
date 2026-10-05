defmodule YellowDog.Management.Repo.Migrations.CreateManagementTasks do
  use Ecto.Migration

  def up do
    Oban.Migration.up(prefix: "management_jobs")

    create table(:management_task_definitions, primary_key: false) do
      add :key, :string, primary_key: true
      add :label, :string, null: false
      add :source, :string, null: false
      add :enabled, :boolean, null: false, default: false
      add :cron, :string, null: false
      add :revision, :integer, null: false, default: 1
      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:management_task_definitions, :management_task_revision_positive,
             check: "revision > 0"
           )

    execute """
    INSERT INTO management_task_definitions (key, label, source, enabled, cron, revision, inserted_at, updated_at)
    VALUES ('ip_city', 'IP City', 'db-ip', false, '30 3 2 * *', 1, now(), now()),
           ('ip_country', 'IP Country', 'db-ip', false, '0 3 2 * *', 1, now(), now()),
           ('mac', 'MAC/OUI', 'wireshark-manuf', false, '0 4 * * SUN', 1, now(), now())
    """

    create table(:management_geoip_artifacts, primary_key: false) do
      add :digest, :string, primary_key: true
      add :path, :text, null: false
      add :size, :bigint, null: false
      add :source_url, :text, null: false
      add :metadata, :map, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create table(:management_geoip_selections, primary_key: false) do
      add :type, :string, primary_key: true

      add :digest,
          references(:management_geoip_artifacts,
            column: :digest,
            type: :string,
            on_delete: :restrict
          ),
          null: false

      add :token, :binary_id, null: false

      add :job_id,
          references(:oban_jobs, prefix: "management_jobs", type: :bigint, on_delete: :restrict),
          null: false

      add :attempt, :integer, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:management_geoip_selections, :management_geoip_selection_type,
             check: "type IN ('city', 'country')"
           )

    create table(:management_task_receipts, primary_key: false) do
      add :job_id,
          references(:oban_jobs, prefix: "management_jobs", type: :bigint, on_delete: :restrict),
          primary_key: true

      add :task_key,
          references(:management_task_definitions,
            column: :key,
            type: :string,
            on_delete: :restrict
          ),
          null: false

      add :result, :map, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    for table <- ["management_geoip_artifacts", "management_task_receipts"] do
      execute "CREATE TRIGGER #{table}_immutable BEFORE UPDATE OR DELETE ON #{table} FOR EACH ROW EXECUTE FUNCTION management_prevent_immutable_change()"
    end
  end

  def down do
    drop table(:management_task_receipts)
    drop table(:management_geoip_selections)
    drop table(:management_geoip_artifacts)
    drop table(:management_task_definitions)
    Oban.Migration.down(prefix: "management_jobs")
  end
end
