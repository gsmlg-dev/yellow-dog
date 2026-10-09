defmodule YellowDog.Management.Repo.Migrations.AddWorkerEnrollmentSettings do
  use Ecto.Migration

  def change do
    create table(:management_worker_enrollment_settings, primary_key: false) do
      add(:id, :integer, primary_key: true)
      add(:allow_anonymous, :boolean, null: false, default: false)
    end

    create constraint(:management_worker_enrollment_settings, :singleton, check: "id = 1")

    execute(
      "INSERT INTO management_worker_enrollment_settings (id, allow_anonymous) VALUES (1, false)",
      "DELETE FROM management_worker_enrollment_settings WHERE id = 1"
    )
  end
end
