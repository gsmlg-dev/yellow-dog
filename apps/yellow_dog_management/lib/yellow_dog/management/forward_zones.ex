defmodule YellowDog.Management.ForwardZones do
  @moduledoc "Management forwarding zones and their desired Worker assignments."

  import Ecto.Changeset, only: [change: 2]
  import Ecto.Query

  alias YellowDog.ConfigSpec
  alias YellowDog.Management.{Access, Database, ForwardZone, Repo, Service, Worker}
  alias YellowDog.Management.ForwardZone.Assignment

  def list(caller) do
    with :ok <- Access.authorize(caller, "config:read") do
      Database.read(fn ->
        zones =
          Repo.all(
            from(zone in ForwardZone,
              left_join: assignment in Assignment,
              on: assignment.forward_zone_id == zone.id,
              group_by: zone.id,
              order_by: [zone.name, zone.id],
              select: {
                zone,
                fragment(
                  "array_remove(array_agg(? ORDER BY ?), NULL)",
                  assignment.worker_id,
                  assignment.worker_id
                )
              }
            )
          )
          |> Enum.map(fn {zone, worker_ids} -> %{zone | worker_ids: worker_ids} end)

        workers =
          Repo.all(from(w in Worker, order_by: [w.name, w.id], select: map(w, [:id, :name])))

        %{zones: zones, workers: workers}
      end)
    end
  end

  def create(caller, params) do
    write(caller, fn ->
      {zone, worker_ids} = input!(params)
      workers = lock_workers!(worker_ids)
      validate_assignments!(zone, worker_ids, nil)

      saved = Repo.insert!(%ForwardZone{name: zone["name"], forwarders: zone["forwarders"]})
      assign_workers(saved.id, worker_ids)
      bump_workers(workers)
      %{saved | worker_ids: worker_ids}
    end)
  end

  def update(caller, id, expected_revision, params) do
    write(caller, fn ->
      saved = lock_zone!(id, expected_revision)
      {zone, worker_ids} = input!(params)
      workers = lock_workers!(Enum.uniq(worker_ids ++ assigned_workers(saved.id)))
      validate_assignments!(zone, worker_ids, saved.id)

      saved =
        saved
        |> change(
          name: zone["name"],
          forwarders: zone["forwarders"],
          revision: saved.revision + 1
        )
        |> Repo.update!()

      Repo.delete_all(from(a in Assignment, where: a.forward_zone_id == ^saved.id))
      assign_workers(saved.id, worker_ids)
      bump_workers(workers)
      %{saved | worker_ids: worker_ids}
    end)
  end

  def delete(caller, id, expected_revision) do
    write(caller, fn ->
      saved = lock_zone!(id, expected_revision)
      workers = lock_workers!(assigned_workers(saved.id))
      Repo.delete!(saved)
      bump_workers(workers)
      :deleted
    end)
  end

  @doc "Load a Worker's forwarding zones in the canonical WorkerPlan shape."
  def target_zones(worker_id) do
    Repo.all(
      from(assignment in Assignment,
        join: zone in ForwardZone,
        on: zone.id == assignment.forward_zone_id,
        where: assignment.worker_id == ^worker_id,
        order_by: zone.name,
        select: %{"name" => zone.name, "forwarders" => zone.forwarders}
      )
    )
  end

  defp write(caller, fun) do
    with :ok <- Access.authorize(caller, "data:write"),
         {:ok, result} <- Database.read(fn -> Repo.transaction(fun) end) do
      result
    end
  end

  defp input!(%{"name" => name, "forwarders" => forwarders, "worker_ids" => ids} = params)
       when map_size(params) == 3 do
    unless is_list(ids) and ids != [] and Enum.all?(ids, &valid_worker_id?/1) and
             length(Enum.uniq(ids)) == length(ids) do
      abort("invalid_workers", "Select one or more distinct registered Workers")
    end

    [zone] = normalize!([%{"name" => name, "forwarders" => forwarders}])
    {zone, Enum.sort(ids)}
  end

  defp input!(_), do: abort("invalid_request", "Enter a suffix, upstreams and Worker assignments")

  defp valid_worker_id?(id) when is_binary(id) and byte_size(id) in 1..64,
    do: Regex.match?(~r/\A[A-Za-z0-9._-]+\z/, id)

  defp valid_worker_id?(_), do: false

  defp normalize!(zones) do
    case ConfigSpec.normalize_forward_zones(zones) do
      {:ok, zones} -> zones
      {:error, [%{code: code, message: message} | _]} -> abort(to_string(code), message)
    end
  end

  defp lock_zone!(id, expected_revision) do
    unless match?({:ok, _}, Ecto.UUID.cast(id)),
      do: abort("forward_zone_not_found", "Forwarding zone not found")

    case Repo.one(from(z in ForwardZone, where: z.id == ^id, lock: "FOR UPDATE")) do
      nil ->
        abort("forward_zone_not_found", "Forwarding zone not found")

      %{revision: ^expected_revision} = zone ->
        zone

      _ ->
        abort("revision_conflict", "The forwarding zone changed. Refresh and review it again.")
    end
  end

  # Target preview and publication take the same Worker locks. Writers always lock
  # the entire affected set in ID order before validating or changing assignments.
  defp lock_workers!(ids) do
    workers =
      Repo.all(
        from(w in Worker, where: w.id in ^ids, order_by: w.id, lock: "FOR UPDATE", select: w.id)
      )

    if length(workers) == length(ids),
      do: workers,
      else: abort("worker_not_found", "One or more selected Workers are no longer registered")
  end

  defp validate_assignments!(zone, worker_ids, previous_zone_id) do
    assigned =
      from(assignment in Assignment,
        join: saved in ForwardZone,
        on: saved.id == assignment.forward_zone_id,
        where: assignment.worker_id in ^worker_ids,
        select: {assignment.worker_id, %{"name" => saved.name, "forwarders" => saved.forwarders}}
      )

    assigned =
      if previous_zone_id do
        where(assigned, [assignment], assignment.forward_zone_id != ^previous_zone_id)
      else
        assigned
      end

    current = assigned |> Repo.all() |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    legacy =
      Repo.all(
        from(service in Service,
          where: service.worker_id in ^worker_ids and service.type == "dns",
          select: {service.worker_id, service.config}
        )
      )
      |> Map.new(fn {id, config} -> {id, config["forward_zones"] || []} end)

    Enum.each(worker_ids, fn worker_id ->
      existing = Map.get(current, worker_id, [])

      if Enum.any?(existing, &(&1["name"] == zone["name"])) do
        abort("forward_zone_conflict", "A selected Worker already has this forwarding suffix")
      end

      assigned_zones = [zone | existing]
      suffixes = MapSet.new(assigned_zones, & &1["name"])

      previous =
        Enum.reject(Map.get(legacy, worker_id, []), &MapSet.member?(suffixes, &1["name"]))

      normalize!(previous ++ assigned_zones)
    end)
  end

  defp assigned_workers(id) do
    Repo.all(from(a in Assignment, where: a.forward_zone_id == ^id, select: a.worker_id))
  end

  defp assign_workers(id, worker_ids) do
    Repo.insert_all(Assignment, Enum.map(worker_ids, &%{forward_zone_id: id, worker_id: &1}))
  end

  defp bump_workers(worker_ids) do
    Repo.update_all(
      from(worker in Worker, where: worker.id in ^worker_ids),
      inc: [revision: 1],
      set: [updated_at: DateTime.utc_now()]
    )
  end

  defp abort(code, message), do: Repo.rollback(%{code: code, message: message})
end
