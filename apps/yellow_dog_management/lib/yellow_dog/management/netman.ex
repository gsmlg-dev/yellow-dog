defmodule YellowDog.Management.Netman do
  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}
  schema "management_netmans" do
    field(:name, :string)
    field(:profile_name, :string, default: "custom")
    field(:apply_mode, :string, default: "managed")
    field(:features, :map, default: %{})
    field(:metadata, :map, default: %{})
    field(:status, :string, default: "not_yet_connected")
    field(:revision, :integer, default: 1)
    timestamps(type: :utc_datetime_usec)
  end
end
