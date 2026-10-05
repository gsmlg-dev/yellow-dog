defmodule YellowDog.Management.NetmanConfigDraft do
  use Ecto.Schema

  @primary_key {:netman_id, :string, autogenerate: false}
  schema "management_netman_config_drafts" do
    field(:revision, :integer, default: 1)
    field(:document, :map)
    timestamps(type: :utc_datetime_usec)
  end
end
