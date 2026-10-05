defmodule YellowDog.Management.NetmanConfigVersion do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "management_netman_config_versions" do
    field(:netman_id, :string)
    field(:version, :integer)
    field(:source_revision, :integer)
    field(:operation, :string)
    field(:document, :map)
    field(:digest, :string)
    field(:rollback_source_id, :binary_id)
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
