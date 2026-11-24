defmodule YellowDog.Management.CloudDns.Provider do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "management_cloud_dns_providers" do
    field(:name, :string)
    field(:kind, :string)
    field(:profile, :string)
    field(:bound?, :boolean, virtual: true, default: false)
    has_many(:bindings, YellowDog.Management.CloudDns.Binding)
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(provider, attrs) do
    provider
    |> cast(attrs, [:name, :kind, :profile])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name, :kind, :profile])
    |> validate_length(:name, max: 128)
    |> validate_inclusion(:kind, ~w(route53 cloudflare))
    |> validate_format(:profile, ~r/^[A-Z][A-Z0-9_]{0,63}$/)
    |> unique_constraint([:kind, :profile])
  end

  def label("route53"), do: "Amazon Route 53"
  def label("cloudflare"), do: "Cloudflare DNS"
end
