defmodule YellowDog.Management.Backup do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "management_backups" do
    field(:label, :string, default: "")
    field(:state, :string, default: "pending")
    field(:job_id, :integer)
    field(:manifest, :map)
    field(:digest, :string)
    field(:size, :integer)
    field(:row_count, :integer)
    field(:completed_at, :utc_datetime_usec)
    field(:error, :string)
    timestamps(type: :utc_datetime_usec)
  end
end
