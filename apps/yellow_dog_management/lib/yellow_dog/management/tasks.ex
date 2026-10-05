defmodule YellowDog.Management.Tasks do
  @moduledoc "PostgreSQL task definitions and the Management-owned durable synchronization queue."
  import Ecto.Query
  alias Oban.Cron.Expression
  alias YellowDog.Management.{Repo, Settings, SyncGeoIPWorker, TaskDefinition, TaskReceipt}

  def list,
    do: Repo.all(from(task in TaskDefinition, order_by: task.key)) |> Enum.map(&task_map/1)

  def get(key) when is_binary(key) do
    case Repo.get(TaskDefinition, key) do
      nil -> {:error, error("not_found", "Task not found")}
      task -> {:ok, task_map(task)}
    end
  end

  def get(_key), do: {:error, error("invalid_request", "Task key must be text")}

  def jobs(key) when is_binary(key) do
    query =
      from(job in Oban.Job,
        where: fragment("?->>'task_key' = ?", job.args, ^key),
        order_by: [desc: job.id],
        limit: 100
      )

    Repo.all(query, prefix: "management_jobs") |> Enum.map(&job_map/1)
  end

  def jobs(_key), do: []

  def history do
    Repo.all(
      from(job in Oban.Job,
        where: job.worker == "YellowDog.Management.SyncGeoIPWorker",
        order_by: [desc: job.id],
        limit: 100
      ),
      prefix: "management_jobs"
    )
    |> Enum.map(&job_map/1)
  end

  def dispatch("update_task", params, _actor) do
    allowed!(params, ~w(key expected_revision enabled cron))
    task = lock_task!(params["key"])
    expected = params["expected_revision"]

    unless is_integer(expected) and expected > 0,
      do: abort("invalid_request", "expected_revision must be a positive integer")

    if expected !== task.revision,
      do: abort("revision_conflict", "Task definition changed; refresh before editing")

    unless is_boolean(params["enabled"]), do: abort("invalid_request", "enabled must be Boolean")
    validate_cron!(params["cron"])

    task
    |> Ecto.Changeset.change(
      enabled: params["enabled"],
      cron: params["cron"],
      revision: task.revision + 1
    )
    |> Repo.update!()
    |> task_map()
  end

  def dispatch("run_task", params, actor) do
    allowed!(params, if(actor == "scheduler", do: ~w(key scheduled_for), else: ~w(key)))
    task = lock_task!(params["key"])

    # TODO(upstream): gsmlg-dev/gsmlg_umbrella#8
    if task.key == "mac",
      do: abort("unavailable", "Lossless MAC sync is blocked by gsmlg-dev/gsmlg_umbrella#8")

    scheduled_for = params["scheduled_for"]

    if actor == "scheduler" do
      with {:ok, time, 0} <- DateTime.from_iso8601(scheduled_for || ""),
           {:ok, expression} <- Expression.parse(task.cron),
           true <- task.enabled and Expression.now?(expression, time) do
        :ok
      else
        _error -> abort("not_due", "Task is not enabled and due at this occurrence")
      end
    end

    type = if task.key == "ip_city", do: :city, else: :country

    args = %{
      "task_key" => task.key,
      "source_url" => Settings.geoip_source(type),
      "scheduled_for" => scheduled_for
    }

    case args |> SyncGeoIPWorker.new() |> Oban.insert() do
      {:ok, job} -> job_map(job)
      {:error, _changeset} -> abort("invalid_request", "Task could not be queued")
    end
  end

  def due(now \\ DateTime.utc_now()) do
    time = now |> DateTime.to_unix() |> then(&DateTime.from_unix!(&1 - rem(&1, 60)))

    Repo.all(
      from(task in TaskDefinition, where: task.enabled and task.key != "mac", order_by: task.key)
    )
    |> Enum.filter(fn task ->
      {:ok, expression} = Expression.parse(task.cron)
      Expression.now?(expression, time)
    end)
    |> Enum.map(fn task ->
      occurrence = DateTime.to_iso8601(time)

      YellowDog.Management.Domain.mutate(
        "run_task",
        %{"key" => task.key, "scheduled_for" => occurrence},
        "scheduler",
        "schedule:#{task.key}:#{occurrence}"
      )
    end)
  end

  def broadcast(key),
    do:
      Phoenix.PubSub.broadcast(
        YellowDog.ManagementUI.PubSub,
        "management:tasks",
        {:task_updated, key}
      )

  def job_map(job) do
    receipt = Repo.get(TaskReceipt, job.id)

    %{
      "id" => job.id,
      "task_key" => job.args["task_key"],
      "state" => to_string(job.state),
      "attempt" => job.attempt,
      "max_attempts" => job.max_attempts,
      "errors" => job.errors,
      "inserted_at" => iso(job.inserted_at),
      "attempted_at" => iso(job.attempted_at),
      "completed_at" => iso(job.completed_at),
      "discarded_at" => iso(job.discarded_at),
      "scheduled_at" => iso(job.scheduled_at),
      "result" => if(receipt, do: receipt.result, else: nil)
    }
  end

  defp task_map(task) do
    last_job = List.first(jobs(task.key))

    status =
      cond do
        task.key == "mac" -> "unavailable"
        is_nil(last_job) -> "idle"
        last_job["state"] in ~w(available scheduled executing retryable) -> "active"
        last_job["state"] == "completed" -> "succeeded"
        last_job["state"] == "discarded" -> "failed"
        true -> "idle"
      end

    %{
      "key" => task.key,
      "label" => task.label,
      "source" => task.source,
      "enabled" => task.enabled,
      "cron" => task.cron,
      "revision" => task.revision,
      "status" => status,
      "available" => task.key != "mac",
      "unavailable_reason" =>
        if(task.key == "mac",
          do: "Lossless MAC sync blocked by gsmlg-dev/gsmlg_umbrella#8",
          else: nil
        ),
      "last_job" => last_job
    }
  end

  defp lock_task!(key) do
    unless is_binary(key) and key in ~w(ip_city ip_country mac),
      do: abort("not_found", "Task not found")

    Repo.one!(from(task in TaskDefinition, where: task.key == ^key, lock: "FOR UPDATE"))
  end

  defp validate_cron!(cron) do
    unless is_binary(cron) and byte_size(cron) in 1..128 and length(String.split(cron)) == 5,
      do: abort("invalid_request", "cron must be a bounded five-field UTC expression")

    case Expression.parse(cron) do
      {:ok, _expression} -> :ok
      {:error, _reason} -> abort("invalid_request", "Invalid cron expression")
    end
  end

  defp allowed!(params, keys) do
    case Enum.find(Map.keys(params), &(&1 not in keys)) do
      nil -> :ok
      key -> abort("invalid_request", "Unsupported field: #{key}")
    end
  end

  defp iso(nil), do: nil
  defp iso(time), do: DateTime.to_iso8601(time)
  defp abort(code, message), do: throw({:management_abort, error(code, message)})
  defp error(code, message), do: %{code: code, message: message, details: %{}}
end
