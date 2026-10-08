defmodule YellowDog.Management.TaskArtifacts do
  @moduledoc "Durable Management-owned MMDB catalog; synchronization never activates a lookup process."
  import Ecto.Query

  alias YellowDog.Management.{
    GeoIPArtifact,
    GeoIPDownload,
    GeoIPSelection,
    Repo,
    TaskDefinition,
    TaskReceipt
  }

  @kinds ~w(city country)
  @page_size 20

  @doc "Bounded metadata-only history. Availability requires a separate byte check."
  def catalog(opts \\ []) do
    selections = Repo.all(GeoIPSelection) |> Map.new(&{&1.type, &1})
    pages = Keyword.get(opts, :pages, %{})

    Enum.map(@kinds, fn kind ->
      page = max(Map.get(pages, kind, 1), 1)

      versions =
        Repo.all(
          from(a in GeoIPArtifact,
            where: a.kind == ^kind,
            order_by: [desc: a.inserted_at, desc: a.digest],
            limit: ^(@page_size + 1),
            offset: ^((page - 1) * @page_size)
          )
        )
        |> Enum.map(&artifact_map/1)

      has_more = length(versions) > @page_size
      versions = Enum.take(versions, @page_size)

      selection = selections[kind]

      selected =
        if selection do
          artifact =
            Enum.find(versions, &(&1.digest == selection.digest)) ||
              artifact_map(Repo.get!(GeoIPArtifact, selection.digest))

          artifact
          |> Map.merge(%{
            selected_at: selection.updated_at,
            job_id: selection.job_id,
            attempt: selection.attempt
          })
        end

      %{
        kind: kind,
        format: "mmdb",
        selected: selected,
        versions: versions,
        page: page,
        has_more: has_more
      }
    end)
  end

  def get(kind, digest) when kind in [:city, :country], do: get(to_string(kind), digest)

  def get(kind, digest) when kind in @kinds and is_binary(digest) do
    case Repo.get(GeoIPArtifact, digest) do
      %GeoIPArtifact{kind: ^kind} = artifact ->
        case check_artifact(artifact) do
          :ok ->
            {:ok,
             Map.merge(artifact_map(artifact), %{
               available: true,
               verification: :verified,
               checked_at: DateTime.utc_now()
             })}

          {:error, reason} ->
            {:error, reason}
        end

      _other ->
        {:error, :not_found}
    end
  end

  def get(kind, _digest) when kind in @kinds, do: {:error, :not_found}
  def get(_kind, _digest), do: {:error, :invalid_kind}

  # Retained source can inspect persisted selections without making them available.
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

  def publish(job, type, artifact) when type in [:city, :country] do
    if job.args["task_key"] == "ip_#{type}" do
      with {:ok, metadata} <- GeoIPDownload.verify(type, artifact) do
        persist_selection(job, type, %{artifact | metadata: metadata})
      end
    else
      {:error, :invalid_job_kind}
    end
  end

  def publish(_job, _type, _artifact), do: {:error, :invalid_kind}

  def restore_receipt(job, %TaskReceipt{job_id: id, task_key: key, result: result})
      when id == job.id do
    if key == job.args["task_key"] and key == "ip_#{result["type"]}" do
      case get(result["type"], result["digest"]) do
        {:ok, _artifact} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :invalid_receipt}
    end
  end

  def restore_receipt(_job, _receipt), do: {:error, :invalid_receipt}

  defp persist_selection(job, type, artifact) do
    case Repo.transaction(fn ->
           # Match task-dispatch lock order; this row also serializes the first selection.
           Repo.one!(
             from(task in TaskDefinition,
               where: task.key == ^job.args["task_key"],
               lock: "FOR UPDATE"
             )
           )

           claim =
             Repo.one!(
               from(queued in Oban.Job,
                 prefix: "management_jobs",
                 where: queued.id == ^job.id,
                 lock: "FOR UPDATE"
               )
             )

           unless claim.state == "executing" and claim.attempt == job.attempt and
                    claim.args == job.args,
                  do: Repo.rollback(:stale_job_claim)

           case receipt(job) do
             nil ->
               publish_selection(job, type, artifact)

             existing ->
               case restore_receipt(job, existing) do
                 :ok -> :ok
                 {:error, reason} -> Repo.rollback(reason)
               end
           end
         end) do
      {:ok, _receipt} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    _error in [Postgrex.Error, Ecto.ConstraintError, DBConnection.ConnectionError] ->
      {:error, :catalog_commit_failed}
  end

  defp publish_selection(job, type, artifact) do
    kind = to_string(type)
    selected = Repo.one(from(s in GeoIPSelection, where: s.type == ^kind, lock: "FOR UPDATE"))
    if selected && selected.job_id > job.id, do: Repo.rollback(:selection_superseded)

    Repo.insert!(
      %GeoIPArtifact{
        digest: artifact.digest,
        kind: kind,
        format: "mmdb",
        path: artifact.path,
        size: artifact.size,
        source_url: artifact.source_url,
        metadata: artifact.metadata
      },
      on_conflict: :nothing
    )

    canonical = Repo.get!(GeoIPArtifact, artifact.digest)

    unless canonical.kind == kind and canonical.format == "mmdb" and
             canonical.size == artifact.size,
           do: Repo.rollback(:artifact_conflict)

    case GeoIPDownload.verify(type, canonical) do
      {:ok, _metadata} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end

    Repo.insert!(
      %GeoIPSelection{
        type: kind,
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
        "type" => kind,
        "format" => "mmdb",
        "digest" => artifact.digest,
        "size" => artifact.size,
        "source_url" => artifact.source_url,
        "metadata" => artifact.metadata,
        "selected_at" => DateTime.to_iso8601(DateTime.utc_now())
      }
    })
  end

  defp artifact_map(artifact) do
    %{
      kind: artifact.kind,
      format: artifact.format,
      digest: artifact.digest,
      size: artifact.size,
      source_url: artifact.source_url,
      metadata: artifact.metadata,
      published_at: artifact.inserted_at,
      available: nil,
      verification: :unverified,
      checked_at: nil,
      availability_error: nil
    }
  end

  defp check_artifact(artifact) do
    if artifact.kind in @kinds and artifact.format == "mmdb",
      do: GeoIPDownload.check_artifact(artifact),
      else: {:error, :unsupported_artifact}
  end

  defp type_atom("city"), do: :city
  defp type_atom("country"), do: :country
end
