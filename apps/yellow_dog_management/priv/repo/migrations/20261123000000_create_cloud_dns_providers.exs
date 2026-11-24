defmodule YellowDog.Management.Repo.Migrations.CreateCloudDnsProviders do
  use Ecto.Migration

  def up do
    create table(:management_cloud_dns_providers, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :kind, :string, null: false
      add :profile, :string, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:management_cloud_dns_providers, [:kind, :profile])

    alter table(:management_cloud_dns_bindings) do
      add :provider_id, references(:management_cloud_dns_providers, type: :binary_id)
    end

    execute """
    INSERT INTO management_cloud_dns_providers (id, name, kind, profile, inserted_at, updated_at)
    SELECT gen_random_uuid(), profile, provider, profile, now(), now()
    FROM (SELECT DISTINCT provider, profile FROM management_cloud_dns_bindings) AS profiles
    """

    execute """
    UPDATE management_cloud_dns_bindings AS b
    SET provider_id = p.id
    FROM management_cloud_dns_providers AS p
    WHERE b.provider = p.kind AND b.profile = p.profile
    """

    drop unique_index(:management_cloud_dns_bindings, [:provider, :remote_id])

    drop index(:management_cloud_dns_bindings, [:provider, :zone_id],
           name: :management_cloud_dns_pending_zone
         )

    alter table(:management_cloud_dns_bindings) do
      modify :provider_id, :binary_id, null: false
      remove :provider
      remove :profile
    end

    create unique_index(:management_cloud_dns_bindings, [:provider_id, :remote_id])

    create unique_index(:management_cloud_dns_bindings, [:provider_id, :zone_id],
             name: :management_cloud_dns_pending_zone,
             where: "remote_id IS NULL"
           )
  end

  def down do
    alter table(:management_cloud_dns_bindings) do
      add :provider, :string
      add :profile, :string
    end

    execute """
    UPDATE management_cloud_dns_bindings AS b
    SET provider = p.kind, profile = p.profile
    FROM management_cloud_dns_providers AS p
    WHERE b.provider_id = p.id
    """

    drop unique_index(:management_cloud_dns_bindings, [:provider_id, :remote_id])

    drop index(:management_cloud_dns_bindings, [:provider_id, :zone_id],
           name: :management_cloud_dns_pending_zone
         )

    alter table(:management_cloud_dns_bindings) do
      modify :provider, :string, null: false
      modify :profile, :string, null: false
      remove :provider_id
    end

    create unique_index(:management_cloud_dns_bindings, [:provider, :remote_id])

    create unique_index(:management_cloud_dns_bindings, [:provider, :zone_id],
             name: :management_cloud_dns_pending_zone,
             where: "remote_id IS NULL"
           )

    drop table(:management_cloud_dns_providers)
  end
end
