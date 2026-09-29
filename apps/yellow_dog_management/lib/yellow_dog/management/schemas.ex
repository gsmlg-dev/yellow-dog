defmodule YellowDog.Management.Worker do
  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}
  schema "management_workers" do
    field(:name, :string)
    field(:expected_capabilities, {:array, :string}, default: [])
    field(:status, :string, default: "not_yet_connected")
    field(:revision, :integer, default: 1)
    has_many(:services, YellowDog.Management.Service)
    has_many(:targets, YellowDog.Management.Target)
    timestamps(type: :utc_datetime_usec)
  end
end

defmodule YellowDog.Management.Zone do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "management_zones" do
    field(:name, :string)
    field(:revision, :integer, default: 1)
    field(:deleted_at, :utc_datetime_usec)
    has_many(:rrsets, YellowDog.Management.Rrset)
    has_many(:versions, YellowDog.Management.ResourceVersion)
    timestamps(type: :utc_datetime_usec)
  end
end

defmodule YellowDog.Management.Rrset do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "management_rrsets" do
    belongs_to(:zone, YellowDog.Management.Zone, type: :binary_id)
    field(:name, :string)
    field(:type, :string)
    field(:ttl, :integer)
    field(:data, {:array, :map})
    timestamps(type: :utc_datetime_usec)
  end
end

defmodule YellowDog.Management.ResourceVersion do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "management_resource_versions" do
    belongs_to(:zone, YellowDog.Management.Zone, type: :binary_id)
    field(:version, :integer)
    field(:source_revision, :integer)
    field(:content, :map)
    field(:digest, :string)
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end

defmodule YellowDog.Management.Service do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "management_services" do
    belongs_to(:worker, YellowDog.Management.Worker, type: :string)
    field(:instance_id, :string)
    field(:type, :string)
    field(:desired_state, :string)
    field(:config, :map)
    has_many(:assignments, YellowDog.Management.Assignment)
    timestamps(type: :utc_datetime_usec)
  end
end

defmodule YellowDog.Management.Assignment do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "management_assignments" do
    belongs_to(:service, YellowDog.Management.Service, type: :binary_id)
    belongs_to(:zone, YellowDog.Management.Zone, type: :binary_id)
    belongs_to(:resource_version, YellowDog.Management.ResourceVersion, type: :binary_id)
    timestamps(type: :utc_datetime_usec)
  end
end

defmodule YellowDog.Management.Target do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "management_targets" do
    belongs_to(:worker, YellowDog.Management.Worker, type: :string)
    field(:revision, :integer)
    field(:plan, :map)
    field(:digest, :string)
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end

defmodule YellowDog.Management.Audit do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "management_audits" do
    field(:actor, :string)
    field(:operation, :string)
    field(:request, :map)
    field(:result, :map)
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end

defmodule YellowDog.Management.Idempotency do
  use Ecto.Schema

  @primary_key {:key, :string, autogenerate: false}
  schema "management_idempotency" do
    field(:request_digest, :string)
    field(:result, :map)
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
