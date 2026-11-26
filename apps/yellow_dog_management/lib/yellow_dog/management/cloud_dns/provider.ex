defmodule YellowDog.Management.CloudDns.Provider do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "management_cloud_dns_providers" do
    field(:name, :string)
    field(:kind, :string)
    field(:profile, :string)
    field(:credentials, :map, redact: true)
    field(:bound?, :boolean, virtual: true, default: false)
    has_many(:bindings, YellowDog.Management.CloudDns.Binding)
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(provider, attrs) do
    provider
    |> cast(attrs, [:name, :kind, :profile])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name, :kind])
    |> validate_length(:name, max: 128)
    |> validate_inclusion(:kind, ~w(route53 cloudflare))
    |> validate_format(:profile, ~r/^[A-Z][A-Z0-9_]{0,63}$/)
    |> put_credentials(attrs)
    |> unique_constraint([:kind, :profile])
  end

  def credential_fields("route53"), do: {~w(access_key_id secret_access_key), "session_token"}
  def credential_fields("cloudflare"), do: {~w(api_token), "account_id"}

  defp put_credentials(%{valid?: false} = changeset, _attrs), do: changeset

  defp put_credentials(changeset, attrs) do
    {required, optional} = credential_fields(get_field(changeset, :kind))
    fields = required ++ [optional]

    existing =
      if changed?(changeset, :kind), do: %{}, else: changeset.data.credentials || %{}

    supplied = Map.take(attrs, fields)

    if Enum.all?(supplied, fn {_, value} -> is_binary(value) and byte_size(value) <= 8192 end) do
      supplied =
        supplied
        |> Map.new(fn {field, value} -> {field, String.trim(value)} end)
        |> Map.reject(fn {_, value} -> value == "" end)

      credentials = Map.merge(existing, supplied)

      credentials =
        if attrs["remove_" <> optional] == true,
          do: Map.delete(credentials, optional),
          else: credentials

      cond do
        Enum.all?(required, &Map.has_key?(credentials, &1)) ->
          changeset |> put_change(:credentials, credentials) |> put_change(:profile, nil)

        map_size(credentials) == 0 and get_field(changeset, :profile) ->
          changeset

        true ->
          add_error(changeset, :credentials, "require all mandatory fields for this provider")
      end
    else
      add_error(changeset, :credentials, "contain an invalid value")
    end
  end

  def label("route53"), do: "Amazon Route 53"
  def label("cloudflare"), do: "Cloudflare DNS"
end
