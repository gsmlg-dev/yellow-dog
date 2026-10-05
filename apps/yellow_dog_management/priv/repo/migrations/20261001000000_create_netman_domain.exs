defmodule YellowDog.Management.Repo.Migrations.CreateNetmanDomain do
  use Ecto.Migration

  def change do
    create table(:management_netmans, primary_key: false) do
      add :id, :string, primary_key: true
      add :name, :string, null: false
      add :profile_name, :string, null: false
      add :apply_mode, :string, null: false
      add :features, :map, null: false
      add :metadata, :map, null: false, default: %{}
      add :status, :string, null: false, default: "not_yet_connected"
      add :revision, :integer, null: false, default: 1
      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:management_netmans, :management_netmans_revision_positive,
             check: "revision > 0"
           )

    create constraint(:management_netmans, :management_netmans_status_logical,
             check: "status = 'not_yet_connected'"
           )

    create constraint(:management_netmans, :management_netmans_apply_mode,
             check: "apply_mode IN ('managed', 'observe_first', 'observe')"
           )

    create table(:management_netman_config_drafts, primary_key: false) do
      add :netman_id, references(:management_netmans, type: :string, on_delete: :restrict),
        primary_key: true

      add :revision, :integer, null: false, default: 1
      add :document, :map, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create constraint(
             :management_netman_config_drafts,
             :management_netman_draft_revision_positive,
             check: "revision > 0"
           )

    create table(:management_netman_config_versions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :netman_id, references(:management_netmans, type: :string, on_delete: :restrict),
        null: false

      add :version, :integer, null: false
      add :source_revision, :integer, null: false
      add :operation, :string, null: false
      add :document, :map, null: false
      add :digest, :string, null: false

      add :rollback_source_id,
          references(:management_netman_config_versions, type: :binary_id, on_delete: :restrict)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:management_netman_config_versions, [:netman_id, :version])
    create unique_index(:management_netman_config_versions, [:id, :netman_id])
    create unique_index(:management_netman_config_versions, [:netman_id, :source_revision])

    create constraint(:management_netman_config_versions, :management_netman_version_positive,
             check: "version > 0 AND source_revision > 0"
           )

    execute """
            ALTER TABLE management_netman_config_versions
            ADD CONSTRAINT management_netman_rollback_node_fk
            FOREIGN KEY (rollback_source_id, netman_id)
            REFERENCES management_netman_config_versions (id, netman_id)
            """,
            "ALTER TABLE management_netman_config_versions DROP CONSTRAINT management_netman_rollback_node_fk"

    execute """
            CREATE TRIGGER management_netman_config_versions_immutable
            BEFORE UPDATE OR DELETE ON management_netman_config_versions
            FOR EACH ROW EXECUTE FUNCTION management_prevent_immutable_change()
            """,
            "DROP TRIGGER management_netman_config_versions_immutable ON management_netman_config_versions"
  end
end
