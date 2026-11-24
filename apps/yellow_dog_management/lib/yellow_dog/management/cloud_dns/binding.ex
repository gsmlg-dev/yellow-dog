defmodule YellowDog.Management.CloudDns.Binding do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "management_cloud_dns_bindings" do
    belongs_to(:provider, YellowDog.Management.CloudDns.Provider, type: :binary_id)
    field(:remote_id, :string)
    field(:zone_id, :binary_id)
    field(:baseline, :map)
    field(:synced_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end
end
