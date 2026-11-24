defmodule YellowDog.Management.DnsViewWorker do
  @moduledoc false
  use Ecto.Schema

  @primary_key false
  schema "management_dns_view_workers" do
    field(:view_id, :binary_id, primary_key: true)
    field(:worker_id, :string, primary_key: true)
  end
end
