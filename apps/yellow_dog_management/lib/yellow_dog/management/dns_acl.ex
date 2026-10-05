defmodule YellowDog.Management.DnsAcl do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "management_dns_acls" do
    belongs_to(:service, YellowDog.Management.Service, type: :binary_id)
    field(:name, :string)
    field(:description, :string, default: "")
    field(:rules, {:array, :map}, default: [])
    field(:revision, :integer, default: 1)
    timestamps(type: :utc_datetime_usec)
  end
end
