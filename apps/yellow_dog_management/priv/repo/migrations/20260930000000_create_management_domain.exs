defmodule YellowDog.Management.Repo.Migrations.CreateManagementDomain do
  use Ecto.Migration

  def change do
    create table(:management_workers, primary_key: false) do
      add :id, :string, primary_key: true
      add :name, :string, null: false
      add :expected_capabilities, {:array, :string}, null: false, default: []
      add :status, :string, null: false, default: "not_yet_connected"
      add :revision, :integer, null: false, default: 1
      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:management_workers, :management_workers_revision_positive,
             check: "revision > 0"
           )

    create constraint(:management_workers, :management_workers_status_logical,
             check: "status = 'not_yet_connected'"
           )

    create table(:management_zones, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :revision, :integer, null: false, default: 1
      add :deleted_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:management_zones, [:name], where: "deleted_at IS NULL")

    create constraint(:management_zones, :management_zones_revision_positive,
             check: "revision > 0"
           )

    create table(:management_rrsets, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :zone_id, references(:management_zones, type: :binary_id, on_delete: :delete_all),
        null: false

      add :name, :string, null: false
      add :type, :string, null: false
      add :ttl, :integer, null: false
      add :data, {:array, :map}, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:management_rrsets, [:zone_id, :name, :type])
    create index(:management_rrsets, [:zone_id])

    create table(:management_resource_versions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :zone_id, references(:management_zones, type: :binary_id, on_delete: :restrict),
        null: false

      add :version, :integer, null: false
      add :source_revision, :integer, null: false
      add :content, :map, null: false
      add :digest, :string, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:management_resource_versions, [:zone_id, :version])
    create unique_index(:management_resource_versions, [:zone_id, :source_revision])
    create unique_index(:management_resource_versions, [:id, :zone_id])

    create table(:management_services, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :worker_id, references(:management_workers, type: :string, on_delete: :restrict),
        null: false

      add :instance_id, :string, null: false
      add :type, :string, null: false
      add :desired_state, :string, null: false
      add :config, :map, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:management_services, [:worker_id, :instance_id])

    create constraint(:management_services, :management_services_desired_state,
             check: "desired_state IN ('running', 'stopped')"
           )

    create table(:management_assignments, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :service_id, references(:management_services, type: :binary_id, on_delete: :delete_all),
        null: false

      add :zone_id, references(:management_zones, type: :binary_id, on_delete: :restrict),
        null: false

      add :resource_version_id,
          references(:management_resource_versions, type: :binary_id, on_delete: :restrict),
          null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:management_assignments, [:service_id, :zone_id])
    create index(:management_assignments, [:resource_version_id])

    execute """
            ALTER TABLE management_assignments
            ADD CONSTRAINT management_assignments_version_zone_fk
            FOREIGN KEY (resource_version_id, zone_id)
            REFERENCES management_resource_versions (id, zone_id)
            ON DELETE RESTRICT
            """,
            "ALTER TABLE management_assignments DROP CONSTRAINT management_assignments_version_zone_fk"

    create table(:management_targets, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :worker_id, references(:management_workers, type: :string, on_delete: :restrict),
        null: false

      add :revision, :integer, null: false
      add :plan, :map, null: false
      add :digest, :string, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:management_targets, [:worker_id, :revision])

    create table(:management_audits, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :actor, :string, null: false
      add :operation, :string, null: false
      add :request, :map, null: false
      add :result, :map, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create table(:management_idempotency, primary_key: false) do
      add :key, :string, primary_key: true
      add :request_digest, :string, null: false
      add :result, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    execute """
            CREATE FUNCTION management_prevent_immutable_change() RETURNS trigger AS $$
            BEGIN
              RAISE EXCEPTION 'confirmed management records are immutable';
            END;
            $$ LANGUAGE plpgsql
            """,
            "DROP FUNCTION management_prevent_immutable_change()"

    for table <- ["management_resource_versions", "management_targets", "management_audits"] do
      execute """
              CREATE TRIGGER #{table}_immutable
              BEFORE UPDATE OR DELETE ON #{table}
              FOR EACH ROW EXECUTE FUNCTION management_prevent_immutable_change()
              """,
              "DROP TRIGGER #{table}_immutable ON #{table}"
    end
  end
end
