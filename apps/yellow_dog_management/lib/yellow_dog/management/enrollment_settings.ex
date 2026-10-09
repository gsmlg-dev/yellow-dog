defmodule YellowDog.Management.EnrollmentSettings do
  @moduledoc "Persisted anonymous Worker enrollment gate and its transaction lock."
  use Ecto.Schema
  import Ecto.Query
  alias YellowDog.Management.Repo

  @primary_key {:id, :integer, autogenerate: false}
  schema "management_worker_enrollment_settings" do
    field(:allow_anonymous, :boolean, default: false)
  end

  def get, do: settings(Repo.get!(__MODULE__, 1))

  def lock do
    Repo.one!(from(s in __MODULE__, where: s.id == 1, lock: "FOR UPDATE"))
  end

  def set(allow_anonymous) when is_boolean(allow_anonymous) do
    lock()
    |> Ecto.Changeset.change(allow_anonymous: allow_anonymous)
    |> Repo.update!()
    |> settings()
  end

  defp settings(row), do: %{"allow_anonymous" => row.allow_anonymous}
end
