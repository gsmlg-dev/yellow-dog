defmodule YellowDog.Management.Repo.Migrations.RemoveStandaloneNetmanDomain do
  use Ecto.Migration

  @operations ~w(create_netman update_netman update_netman_config confirm_netman_config rollback_netman_config)

  def up do
    # Older receipts do not store their operation. Reconstruct only fingerprints
    # proven by a Netman audit; projected audits may not retain the full request.
    %{rows: audits} =
      repo().query!(
        "SELECT actor, operation, request FROM management_audits WHERE operation = ANY($1)",
        [@operations]
      )

    for [actor, operation, request] <- audits do
      fingerprint =
        :crypto.hash(
          :sha256,
          :erlang.term_to_binary({operation, actor, canonical(request)}, [:deterministic])
        )
        |> Base.encode16(case: :lower)

      repo().query!("DELETE FROM management_idempotency WHERE request_digest = $1", [fingerprint])
    end

    # Successful Netman results have exclusive top-level shapes. Generic failed
    # receipts with projected audit requests cannot be attributed safely and stay.
    execute """
    DELETE FROM management_idempotency
    WHERE result->'ok' ? 'netman_id'
       OR result->'ok' ?& ARRAY['profile_name', 'apply_mode', 'features']
    """

    # Keep the shared audit table and restore its immutable guard in this same
    # migration transaction. No other business audit is removed.
    execute "ALTER TABLE management_audits DISABLE TRIGGER management_audits_immutable"

    execute """
    DELETE FROM management_audits
    WHERE operation IN ('create_netman', 'update_netman', 'update_netman_config',
                        'confirm_netman_config', 'rollback_netman_config')
    """

    execute "ALTER TABLE management_audits ENABLE TRIGGER management_audits_immutable"

    drop table(:management_netman_config_versions)
    drop table(:management_netman_config_drafts)
    drop table(:management_netmans)
  end

  def down do
    raise Ecto.MigrationError,
          "Standalone Netman data was removed; restore a pre-migration backup to recover it"
  end

  defp canonical(map) when is_map(map),
    do: map |> Enum.map(fn {key, value} -> {key, canonical(value)} end) |> Enum.sort()

  defp canonical(list) when is_list(list), do: Enum.map(list, &canonical/1)
  defp canonical(value), do: value
end
