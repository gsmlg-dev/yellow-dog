# Start only a database client and the public Domain boundary in a fresh VM. The
# caller seeds atom names before Elixir loads, then supplies committed fixtures.
input =
  System.fetch_env!("YD_ASSIGNMENT_VM_INPUT") |> Base.decode64!() |> :erlang.binary_to_term()

for application <- [:crypto, :ssl, :ecto_sql, :postgrex] do
  {:ok, _} = Application.ensure_all_started(application)
end

alias YellowDog.Management.{Assignment, Domain, Idempotency, Repo}
import Ecto.Query

Application.put_env(:yellow_dog_management, Repo, input.config)
{:ok, _repo} = Repo.start_link()
{:ok, snapshot} = Domain.get_zone_assignments(input.zone_id)
{:ok, replayed} = Domain.mutate("set_zone_assignments", input.command, input.actor, input.key)

rows = Repo.all(from(a in Assignment, where: a.zone_id == ^input.zone_id))

raw =
  rows |> Enum.map(&{&1.id, &1.service_id, &1.resource_version_id, &1.updated_at}) |> Enum.sort()

raw_digest =
  :crypto.hash(:sha256, :erlang.term_to_binary({input.zone_id, raw}))
  |> Base.encode16(case: :lower)

IO.puts(
  "YD_ASSIGNMENT_VM:" <>
    Jason.encode!(%{
      snapshot: snapshot,
      replayed: replayed,
      request_digest: Repo.get!(Idempotency, input.key).request_digest,
      raw_snapshot_digest: raw_digest
    })
)
