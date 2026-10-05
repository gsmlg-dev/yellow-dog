defmodule YellowDog.Management.TaskArtifacts do
  import Ecto.Query
  alias YellowDog.Management.{GeoIP, GeoIPArtifact, GeoIPSelection, Repo, TaskReceipt}

  def selected_artifacts do
    Repo.all(
      from(selection in GeoIPSelection,
        join: artifact in GeoIPArtifact,
        on: artifact.digest == selection.digest,
        select: {selection.type, artifact}
      )
    )
    |> Map.new(fn {type, artifact} -> {type_atom(type), artifact} end)
  end

  def receipt(job), do: Repo.get(TaskReceipt, job.id)

  def activate(job, type, artifact, server \\ GeoIP) do
    GeoIP.activate(
      type,
      artifact.path,
      fn loaded ->
        if loaded.digest != artifact.digest do
          {:error, :artifact_digest_mismatch}
        else
          persist_selection(job, type, artifact)
        end
      end,
      server
    )
  end

  def restore_receipt(job, receipt, server \\ GeoIP) do
    result = receipt.result
    artifact = Repo.get!(GeoIPArtifact, result["digest"])
    type = type_atom(result["type"])
    selection = Repo.get(GeoIPSelection, result["type"])

    if selection && selection.job_id == job.id do
      GeoIP.activate(
        type,
        artifact.path,
        fn loaded ->
          current = Repo.get(GeoIPSelection, result["type"])

          if loaded.digest == artifact.digest and not is_nil(current) and
               current.token == selection.token,
             do: :ok,
             else: {:error, :selection_changed}
        end,
        server
      )
    else
      :ok
    end
  end

  defp persist_selection(job, type, artifact) do
    case Repo.transaction(fn ->
           claim =
             Repo.one!(
               from(queued in Oban.Job,
                 prefix: "management_jobs",
                 where: queued.id == ^job.id,
                 lock: "FOR UPDATE"
               )
             )

           unless claim.state == "executing" and claim.attempt == job.attempt,
             do: Repo.rollback(:stale_job_claim)

           now = DateTime.utc_now()

           Repo.insert!(
             %GeoIPArtifact{
               digest: artifact.digest,
               path: artifact.path,
               size: artifact.size,
               source_url: artifact.source_url,
               metadata: artifact.metadata
             },
             on_conflict: :nothing
           )

           Repo.insert!(
             %GeoIPSelection{
               type: to_string(type),
               digest: artifact.digest,
               token: Ecto.UUID.generate(),
               job_id: job.id,
               attempt: job.attempt
             },
             on_conflict: {:replace, [:digest, :token, :job_id, :attempt, :updated_at]},
             conflict_target: :type
           )

           Repo.insert!(%TaskReceipt{
             job_id: job.id,
             task_key: job.args["task_key"],
             result: %{
               "type" => to_string(type),
               "digest" => artifact.digest,
               "size" => artifact.size,
               "source_url" => artifact.source_url,
               "metadata" => artifact.metadata,
               "selected_at" => DateTime.to_iso8601(now)
             }
           })
         end) do
      {:ok, _receipt} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp type_atom("city"), do: :city
  defp type_atom("country"), do: :country
end
