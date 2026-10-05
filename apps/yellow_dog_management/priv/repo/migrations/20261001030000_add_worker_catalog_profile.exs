defmodule YellowDog.Management.Repo.Migrations.AddWorkerCatalogProfile do
  use Ecto.Migration

  def change do
    alter table(:management_workers) do
      add :profile_name, :string, null: false, default: "custom"
    end

    create constraint(:management_workers, :management_worker_catalog_profile,
             check:
               "profile_name IN ('cloud_dns', 'local_network', 'dns_only', 'dhcp_only', 'netboot_only', 'custom')"
           )
  end
end
