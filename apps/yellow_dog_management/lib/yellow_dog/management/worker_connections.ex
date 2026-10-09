defmodule YellowDog.Management.WorkerConnections do
  @moduledoc "Worker enrollment credentials and authenticated runtime observations."
  import Ecto.Query
  alias YellowDog.Management.{Audit, Domain, EnrollmentSettings, Repo, Worker}

  @report_keys ~w(worker_id capabilities services applied_revision applied_digest apply_error)
  @id ~r/^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/
  @digest ~r/^[a-f0-9]{64}$/
  @errors ~w(request_failed invalid_response invalid_target apply_failed stale_target identity_mismatch digest_mismatch connection_failed)

  def create(name) do
    if is_binary(name) && byte_size(name) in 1..128 && String.valid?(name) &&
         String.trim(name) == name && not String.contains?(name, <<0>>) do
      enroll(name)
    else
      {:error, error("invalid_request", "Name must be a bounded nonempty string")}
    end
  end

  defp enroll(name) do
    token = new_token()

    case Repo.transaction(fn ->
           case Domain.mutate(
                  "create_worker",
                  %{
                    "id" => Ecto.UUID.generate(),
                    "name" => name,
                    "expected_capabilities" => ["dns"]
                  },
                  "operator",
                  Ecto.UUID.generate()
                ) do
             {:ok, worker} ->
               Repo.get!(Worker, worker["id"])
               |> Ecto.Changeset.change(connection_token_hash: hash(token))
               |> Repo.update!()

               worker

             {:error, error} ->
               Repo.rollback(error)
           end
         end) do
      {:ok, worker} -> {:ok, %{"worker" => worker, "token" => token}}
      {:error, error} -> {:error, error}
    end
  end

  def rotate(worker_id) do
    token = new_token()

    case Repo.transaction(fn ->
           worker = locked_worker(worker_id)
           if is_nil(worker), do: Repo.rollback(error("not_found", "Worker not found"))

           worker
           |> Ecto.Changeset.change(connection_token_hash: hash(token), last_seen_at: nil)
           |> Repo.update!()

           Repo.insert!(%Audit{
             actor: "operator",
             operation: "rotate_worker_token",
             request: %{"worker_id" => worker_id},
             result: %{"worker_id" => worker_id}
           })

           {:ok, result} = Domain.get_worker(worker_id)
           result
         end) do
      {:ok, worker} -> {:ok, %{"worker" => worker, "token" => token}}
      {:error, error} -> {:error, error}
    end
  end

  def bootstrap(worker, token, management_url) do
    "worker_id = #{Jason.encode!(worker["id"])}\ndata_dir = \"data\"\n" <>
      "management_url = #{Jason.encode!(management_url)}\n" <>
      "token = #{Jason.encode!(token)}\npoll_interval_ms = 10000\n"
  end

  def connection_fields(worker) do
    status =
      cond do
        is_nil(worker.last_seen_at) -> "not_yet_connected"
        DateTime.diff(DateTime.utc_now(), worker.last_seen_at, :second) < 45 -> "connected"
        true -> "offline"
      end

    %{
      "connection_status" => status,
      "last_seen_at" => if(worker.last_seen_at, do: DateTime.to_iso8601(worker.last_seen_at)),
      "reported_capabilities" => worker.reported_capabilities,
      "reported_services" => worker.reported_services,
      "applied_revision" => worker.applied_revision,
      "applied_digest" => worker.applied_digest,
      "apply_error" => worker.apply_error
    }
  end

  def connect(token, report) when is_binary(token) and is_map(report) do
    Repo.transaction(fn ->
      worker = locked_worker(report["worker_id"]) || initialize_worker(token, report)

      unless worker && is_binary(worker.connection_token_hash) &&
               Plug.Crypto.secure_compare(worker.connection_token_hash, hash(token)),
             do: Repo.rollback(error("unauthorized", "Invalid Worker credential"))

      unless valid_report?(report) && valid_applied?(worker.id, report),
        do: Repo.rollback(error("invalid_report", "Invalid Worker runtime report"))

      worker
      |> Ecto.Changeset.change(
        last_seen_at: DateTime.utc_now(),
        reported_capabilities: report["capabilities"],
        reported_services: report["services"],
        applied_revision: report["applied_revision"],
        applied_digest: report["applied_digest"],
        apply_error: report["apply_error"]
      )
      |> Repo.update!()

      target =
        case Domain.get_target(worker.id) do
          {:ok, target} -> Map.take(target, ~w(revision digest plan))
          {:error, _} -> nil
        end

      %{"worker_id" => worker.id, "target" => target}
    end)
  end

  def connect(_, _), do: {:error, error("unauthorized", "Invalid Worker credential")}

  defp initialize_worker(token, report) do
    unless valid_initial_report?(report) && valid_initial_token?(token),
      do: Repo.rollback(error("unauthorized", "Invalid Worker credential"))

    settings = EnrollmentSettings.lock()
    id = report["worker_id"]

    case locked_worker(id) do
      %Worker{} = worker ->
        worker

      nil ->
        unless settings.allow_anonymous,
          do: Repo.rollback(error("unauthorized", "Invalid Worker credential"))

        case Domain.mutate(
               "create_worker",
               %{"id" => id, "name" => "Worker #{id}", "expected_capabilities" => ["dns"]},
               "anonymous_worker",
               "anonymous_worker:#{id}"
             ) do
          {:ok, _} ->
            Repo.get!(Worker, id)
            |> Ecto.Changeset.change(connection_token_hash: hash(token))
            |> Repo.update!()

          {:error, error} ->
            Repo.rollback(error)
        end
    end
  end

  defp valid_initial_report?(report) do
    id = report["worker_id"]

    valid_report?(report) && is_binary(id) && match?({:ok, ^id}, Ecto.UUID.cast(id)) &&
      report["services"] == %{} && is_nil(report["applied_revision"]) &&
      is_nil(report["applied_digest"]) && is_nil(report["apply_error"])
  end

  defp valid_initial_token?(token) when byte_size(token) == 43 do
    case Base.url_decode64(token, padding: false) do
      {:ok, bytes} when byte_size(bytes) == 32 ->
        Base.url_encode64(bytes, padding: false) == token

      _ ->
        false
    end
  end

  defp valid_initial_token?(_), do: false

  defp valid_report?(report) do
    Map.keys(report) -- @report_keys == [] &&
      Enum.all?(@report_keys, &Map.has_key?(report, &1)) &&
      report["capabilities"] == ["dns"] && valid_services?(report["services"]) &&
      report["apply_error"] in [nil | @errors]
  end

  defp valid_services?(services) when is_map(services) and map_size(services) <= 64 do
    Enum.all?(services, fn {id, observation} ->
      is_binary(id) && Regex.match?(@id, id) && is_map(observation) &&
        Map.keys(observation) == ["state"] && observation["state"] in ~w(running stopped error)
    end)
  end

  defp valid_services?(_), do: false

  defp valid_applied?(id, report) do
    case {report["applied_revision"], report["applied_digest"]} do
      {nil, nil} ->
        true

      {revision, digest}
      when is_integer(revision) and revision in 1..2_147_483_647 and is_binary(digest) ->
        Regex.match?(@digest, digest) &&
          case Domain.get_target(id, revision) do
            {:ok, %{"digest" => ^digest}} -> true
            _ -> false
          end

      _ ->
        false
    end
  end

  defp locked_worker(id) when is_binary(id) and byte_size(id) <= 64,
    do: Repo.one(from(w in Worker, where: w.id == ^id, lock: "FOR UPDATE"))

  defp locked_worker(_), do: nil
  defp new_token, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  defp hash(token), do: :crypto.hash(:sha256, token)
  defp error(code, message), do: %{code: code, message: message}
end
