defmodule YellowDog.Management.Repo.Migrations.AddCloudDnsProviderCredentials do
  use Ecto.Migration

  def up do
    alter table(:management_cloud_dns_providers) do
      add :credentials, :map
      modify :profile, :string, null: true
    end

    create constraint(:management_cloud_dns_providers, :cloud_dns_credential_source,
             check: "(profile IS NULL) <> (credentials IS NULL)"
           )
  end

  def down do
    drop constraint(:management_cloud_dns_providers, :cloud_dns_credential_source)

    alter table(:management_cloud_dns_providers) do
      modify :profile, :string, null: false
      remove :credentials
    end
  end
end
