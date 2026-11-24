defmodule YellowDog.Management.Repo.Migrations.CreateDNSCertificates do
  use Ecto.Migration

  def change do
    create table(:management_dns_certificates, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :revision, :integer, null: false, default: 1
      add :certificate_pem, :text, null: false
      add :private_key_pem, :text, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:management_dns_certificates, [:name])
  end
end
