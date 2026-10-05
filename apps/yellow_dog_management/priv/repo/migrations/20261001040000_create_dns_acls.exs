defmodule YellowDog.Management.Repo.Migrations.CreateDnsAcls do
  use Ecto.Migration

  def change do
    create table(:management_dns_acls, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :service_id, references(:management_services, type: :uuid, on_delete: :restrict),
        null: false

      add :name, :string, size: 128, null: false
      add :networks, {:array, :text}, null: false, default: []
      add :action, :string, null: false
      add :revision, :bigint, null: false, default: 1
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:management_dns_acls, [:service_id, :name])

    create constraint(:management_dns_acls, :management_dns_acl_name,
             check: "name ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'"
           )

    create constraint(:management_dns_acls, :management_dns_acl_action,
             check: "action IN ('allow', 'deny')"
           )

    create constraint(:management_dns_acls, :management_dns_acl_revision_positive,
             check: "revision > 0"
           )

    create constraint(:management_dns_acls, :management_dns_acl_networks,
             check:
               "cardinality(networks) <= 128 AND array_position(networks, NULL) IS NULL AND networks::cidr[]::text[] = networks"
           )
  end
end
