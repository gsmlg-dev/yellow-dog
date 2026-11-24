defmodule YellowDog.Management.Repo.Migrations.CreateCloudDnsBindings do
  use Ecto.Migration

  def change do
    create table(:management_cloud_dns_bindings, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :provider, :string, null: false
      add :profile, :string, null: false
      add :remote_id, :string
      add :zone_id, references(:management_zones, type: :binary_id)
      add :baseline, :map
      add :synced_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:management_cloud_dns_bindings, [:provider, :remote_id])

    create unique_index(:management_cloud_dns_bindings, [:provider, :zone_id],
             name: :management_cloud_dns_pending_zone,
             where: "remote_id IS NULL"
           )
  end
end
