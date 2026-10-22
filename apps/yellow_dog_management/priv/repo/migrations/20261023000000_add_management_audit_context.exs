defmodule YellowDog.Management.Repo.Migrations.AddManagementAuditContext do
  use Ecto.Migration

  def change do
    alter table(:management_audits) do
      add :context, :map, null: false, default: %{}
    end
  end
end
