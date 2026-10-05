defmodule YellowDog.Management.DnsView do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "management_dns_views" do
    belongs_to(:service, YellowDog.Management.Service, type: :binary_id)
    field(:name, :string)
    field(:is_default, :boolean, default: false)
    field(:priority, :integer, default: 100)
    field(:enabled, :boolean, default: true)
    field(:recursion_enabled, :boolean, default: true)
    field(:ecs_enabled, :boolean, default: false)
    field(:client_rules, {:array, :map}, default: [%{"action" => "allow", "kind" => "any"}])
    field(:fallback_forwarders, {:array, :map}, default: [])
    field(:fallback_timeout, :integer, default: 2000)
    field(:fallback_retries, :integer, default: 1)
    field(:revision, :integer, default: 1)
    timestamps(type: :utc_datetime_usec)
  end
end
