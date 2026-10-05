defmodule YellowDog.Management.TaskDefinition do
  use Ecto.Schema
  @primary_key {:key, :string, autogenerate: false}
  schema "management_task_definitions" do
    field(:label, :string)
    field(:source, :string)
    field(:enabled, :boolean, default: false)
    field(:cron, :string)
    field(:revision, :integer, default: 1)
    timestamps(type: :utc_datetime_usec)
  end
end

defmodule YellowDog.Management.GeoIPArtifact do
  use Ecto.Schema
  @primary_key {:digest, :string, autogenerate: false}
  schema "management_geoip_artifacts" do
    field(:kind, :string)
    field(:format, :string)
    field(:path, :string)
    field(:size, :integer)
    field(:source_url, :string)
    field(:metadata, :map)
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end

defmodule YellowDog.Management.GeoIPSelection do
  use Ecto.Schema
  @primary_key {:type, :string, autogenerate: false}
  schema "management_geoip_selections" do
    field(:digest, :string)
    field(:token, :binary_id)
    field(:job_id, :integer)
    field(:attempt, :integer)
    timestamps(type: :utc_datetime_usec)
  end
end

defmodule YellowDog.Management.TaskReceipt do
  use Ecto.Schema
  @primary_key {:job_id, :integer, autogenerate: false}
  schema "management_task_receipts" do
    field(:task_key, :string)
    field(:result, :map)
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
