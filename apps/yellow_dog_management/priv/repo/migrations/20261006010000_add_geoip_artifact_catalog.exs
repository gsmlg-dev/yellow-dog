defmodule YellowDog.Management.Repo.Migrations.AddGeoIPArtifactCatalog do
  use Ecto.Migration

  def change do
    alter table(:management_geoip_artifacts) do
      add :kind, :string
      add :format, :string
    end

    create constraint(:management_geoip_artifacts, :management_geoip_artifact_kind,
             check: "kind IN ('city', 'country')"
           )

    create constraint(:management_geoip_artifacts, :management_geoip_artifact_format,
             check: "format = 'mmdb'"
           )

    create index(:management_geoip_artifacts, [:kind, :inserted_at])
  end
end
