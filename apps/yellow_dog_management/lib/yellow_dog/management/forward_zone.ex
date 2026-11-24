defmodule YellowDog.Management.ForwardZone do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "management_dns_forward_zones" do
    field(:name, :string)
    field(:forwarders, {:array, :map})
    field(:revision, :integer, default: 1)
    field(:worker_ids, {:array, :string}, virtual: true, default: [])
    timestamps(type: :utc_datetime_usec)
  end

  defmodule Assignment do
    @moduledoc false
    use Ecto.Schema

    @primary_key false
    schema "management_dns_forward_zone_workers" do
      field(:forward_zone_id, :binary_id, primary_key: true)
      field(:worker_id, :string, primary_key: true)
    end
  end
end
