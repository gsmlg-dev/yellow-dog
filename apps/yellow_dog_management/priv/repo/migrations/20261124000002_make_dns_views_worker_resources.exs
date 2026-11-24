defmodule YellowDog.Management.Repo.Migrations.MakeDnsViewsWorkerResources do
  use Ecto.Migration

  def up do
    create table(:management_dns_view_workers, primary_key: false) do
      add :view_id, references(:management_dns_views, type: :uuid, on_delete: :delete_all),
        primary_key: true

      add :worker_id, references(:management_workers, type: :string, on_delete: :restrict),
        primary_key: true
    end

    create index(:management_dns_view_workers, [:worker_id])

    alter table(:management_dns_views) do
      modify :service_id, :uuid, null: true
    end

    execute """
    INSERT INTO management_dns_view_workers (view_id, worker_id)
    SELECT view.id, service.worker_id
    FROM management_dns_views AS view
    JOIN management_services AS service ON service.id = view.service_id
    WHERE NOT view.is_default
    """

    execute "UPDATE management_dns_views SET service_id = NULL WHERE NOT is_default"

    create constraint(:management_dns_views, :management_dns_view_scope,
             check: "is_default = (service_id IS NOT NULL)"
           )
  end

  def down do
    raise Ecto.MigrationError,
      message:
        "A DNS View can now belong to multiple Workers; restore a pre-migration backup to roll back."
  end
end
