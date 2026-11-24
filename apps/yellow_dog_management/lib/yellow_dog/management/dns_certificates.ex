defmodule YellowDog.Management.DnsCertificates do
  @moduledoc "Management certificate catalog and references from saved DNS settings and targets."
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias YellowDog.Management.{Access, Repo, Service, Target}
  alias YellowDog.ManagementUI.PubSub

  @topic "dns_certificates"
  @max_pem_bytes 65_536
  @metadata [:id, :name, :revision, :updated_at]
  @tls_protocols ~w(dot doq doh)
  @primary_key {:id, :binary_id, autogenerate: true}

  schema "management_dns_certificates" do
    field(:name, :string)
    field(:revision, :integer, default: 1)
    field(:certificate_pem, :string)
    field(:private_key_pem, :string, redact: true)
    timestamps(type: :utc_datetime_usec)
  end

  def list do
    Repo.all(from(c in __MODULE__, order_by: c.name, select: map(c, ^@metadata)))
  end

  def subscribe, do: Phoenix.PubSub.subscribe(PubSub, @topic)

  def create(caller, params) do
    with :ok <- Access.ui_admin(caller),
         {:ok, row} <- Repo.insert(changeset(%__MODULE__{}, params), log: false) do
      {:ok, Map.take(row, @metadata)}
    end
  end

  def replace(caller, id, revision, params) do
    with :ok <- Access.ui_admin(caller),
         {:ok, row} <-
           Repo.transaction(fn ->
             row = lock!(id)
             require_revision!(row, revision)

             result =
               %{row | certificate_pem: nil, private_key_pem: nil}
               |> changeset(params)
               |> put_change(:revision, row.revision + 1)
               |> Repo.update(log: false)

             case result do
               {:ok, updated} -> updated
               {:error, error} -> Repo.rollback(error)
             end
           end) do
      :ok = Phoenix.PubSub.broadcast(PubSub, @topic, {:dns_certificate_updated, row.id})
      {:ok, Map.take(row, @metadata)}
    end
  end

  def delete(caller, id, revision) do
    with :ok <- Access.ui_admin(caller) do
      Repo.transaction(fn ->
        row = lock!(id)
        require_revision!(row, revision)

        case usage(row.id) do
          [] ->
            Repo.delete!(row, log: false)
            :ok

          refs ->
            Repo.rollback(%{code: "certificate_in_use", references: refs})
        end
      end)
    end
  end

  def validate_references(configs) do
    ids = configs |> Enum.flat_map(&certificate_ids/1) |> Enum.uniq() |> Enum.sort()

    case Enum.split_with(ids, &match?({:ok, _}, Ecto.UUID.cast(&1))) do
      {[], []} ->
        :ok

      {uuids, []} ->
        available =
          Repo.all(
            from(c in __MODULE__,
              where: c.id in ^uuids,
              select: c.id,
              order_by: c.id,
              lock: "FOR SHARE"
            )
          )

        case uuids -- available do
          [] -> :ok
          missing -> {:error, missing}
        end

      {_uuids, invalid} ->
        {:error, invalid}
    end
  end

  def target_ids(%{"plan" => %{"services" => services}}) do
    ids =
      for %{"desired_state" => "running", "config" => config} <- services,
          protocol <- @tls_protocols,
          %{"enabled" => true, "certificate_id" => id} <- [
            get_in(config, ["transports", protocol])
          ],
          do: id

    Enum.uniq(ids)
  end

  def target_ids(_), do: []

  def payloads([]), do: []

  def payloads(ids) do
    ids = Enum.filter(ids, &match?({:ok, _}, Ecto.UUID.cast(&1)))

    Repo.all(
      from(c in __MODULE__,
        where: c.id in ^ids,
        order_by: c.id,
        select: %{
          "id" => c.id,
          "revision" => c.revision,
          "certificate_pem" => c.certificate_pem,
          "private_key_pem" => c.private_key_pem
        }
      ),
      log: false
    )
  end

  defp usage(id) do
    saved =
      Repo.all(from(s in Service, where: s.type == "dns", select: {s.worker_id, s.config}))

    confirmed =
      Repo.all(
        from(t in Target,
          distinct: t.worker_id,
          order_by: [desc: t.revision],
          select: {t.worker_id, fragment("?->'services'", t.plan)}
        )
      )
      |> Enum.flat_map(fn {worker_id, services} ->
        for %{"config" => config} <- services, do: {worker_id, config}
      end)

    for {worker_id, config} <- saved ++ confirmed,
        protocol <- @tls_protocols,
        get_in(config, ["transports", protocol, "certificate_id"]) == id,
        uniq: true,
        do: %{worker_id: worker_id, protocol: protocol}
  end

  defp certificate_ids(config) do
    for protocol <- @tls_protocols,
        id = get_in(config, ["transports", protocol, "certificate_id"]),
        do: id
  end

  defp lock!(id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %__MODULE__{} = row <-
           Repo.one(from(c in __MODULE__, where: c.id == ^id, lock: "FOR UPDATE")) do
      row
    else
      _ -> Repo.rollback(%{code: "not_found"})
    end
  end

  defp require_revision!(%{revision: revision}, revision), do: :ok
  defp require_revision!(_row, _revision), do: Repo.rollback(%{code: "revision_conflict"})

  defp changeset(row, params) do
    row
    |> cast(params, [:name, :certificate_pem, :private_key_pem])
    |> validate_required([:name, :certificate_pem, :private_key_pem])
    |> validate_length(:name, max: 128)
    |> validate_change(:certificate_pem, &validate_pem/2)
    |> validate_change(:private_key_pem, &validate_pem/2)
    |> unique_constraint(:name)
  end

  defp validate_pem(field, data) when byte_size(data) <= @max_pem_bytes do
    entries = :public_key.pem_decode(data)

    valid? =
      case {field, entries} do
        {:certificate_pem, [_ | _]} ->
          Enum.all?(entries, fn
            {:Certificate, der, :not_encrypted} ->
              match?({:OTPCertificate, _, _, _}, :public_key.pkix_decode_cert(der, :otp))

            _ ->
              false
          end)

        {:private_key_pem, [{type, _, :not_encrypted} = entry]}
        when type in [:RSAPrivateKey, :ECPrivateKey, :PrivateKeyInfo] ->
          _key = :public_key.pem_entry_decode(entry)
          true

        _ ->
          false
      end

    if valid?, do: [], else: [{field, "must contain valid PEM data"}]
  rescue
    _ -> [{field, "must contain valid PEM data"}]
  end

  defp validate_pem(field, _data), do: [{field, "exceeds the maximum PEM size"}]
end
