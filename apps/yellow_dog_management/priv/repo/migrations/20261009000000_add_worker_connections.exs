defmodule YellowDog.Management.Repo.Migrations.AddWorkerConnections do
  use Ecto.Migration

  def change do
    alter table(:management_workers) do
      add(:connection_token_hash, :binary)
      add(:last_seen_at, :utc_datetime_usec)
      add(:reported_capabilities, {:array, :string}, null: false, default: [])
      add(:reported_services, :map, null: false, default: %{})
      add(:applied_revision, :integer)
      add(:applied_digest, :string)
      add(:apply_error, :string)
    end
  end
end
