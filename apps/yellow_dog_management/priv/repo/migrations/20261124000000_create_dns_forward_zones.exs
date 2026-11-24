defmodule YellowDog.Management.Repo.Migrations.CreateDnsForwardZones do
  use Ecto.Migration

  def change do
    create table(:management_dns_forward_zones, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :forwarders, {:array, :map}, null: false
      add :revision, :integer, null: false, default: 1
      timestamps(type: :utc_datetime_usec)
    end

    create index(:management_dns_forward_zones, [:name])

    create constraint(:management_dns_forward_zones, :management_dns_forward_zones_values_valid,
             check: "revision > 0 AND cardinality(forwarders) BETWEEN 1 AND 8"
           )

    create table(:management_dns_forward_zone_workers, primary_key: false) do
      add :forward_zone_id,
          references(:management_dns_forward_zones, type: :binary_id, on_delete: :delete_all),
          primary_key: true

      add :worker_id, references(:management_workers, type: :string, on_delete: :restrict),
        primary_key: true
    end

    create index(:management_dns_forward_zone_workers, [:worker_id])
  end
end
