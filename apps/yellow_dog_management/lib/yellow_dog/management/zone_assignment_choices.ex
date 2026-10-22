defmodule YellowDog.Management.ZoneAssignmentChoices do
  @moduledoc "Narrow identities and bounded service choices for the Zone application editor."
  import Ecto.Query
  alias YellowDog.Management.{Repo, Service, Worker}

  @page_size 20

  def navigation do
    Repo.all(
      from(w in Worker, order_by: [w.name, w.id], select: %{"id" => w.id, "name" => w.name})
    )
  end

  def candidates(options \\ %{}) do
    search =
      if is_binary(options["search"]), do: String.slice(options["search"], 0, 253), else: ""

    page = page(options["page"])

    query =
      from(w in Worker,
        left_join: s in Service,
        on: s.worker_id == w.id and s.type == "dns"
      )

    query =
      if search == "" do
        query
      else
        from([w, s] in query,
          where:
            fragment("strpos(lower(?), lower(?)) > 0", w.name, ^search) or
              fragment("strpos(lower(?), lower(?)) > 0", w.id, ^search) or
              fragment("strpos(lower(coalesce(?, '')), lower(?)) > 0", s.instance_id, ^search)
        )
      end

    total = Repo.aggregate(query, :count)

    rows =
      Repo.all(
        from([w, s] in query,
          order_by: [w.name, w.id, s.instance_id, s.id],
          offset: ^((page - 1) * @page_size),
          limit: @page_size,
          select: {w.id, w.name, s.id, s.instance_id}
        )
      )

    workers =
      rows
      |> Enum.group_by(fn {id, _, _, _} -> id end)
      |> Enum.map(fn {id, rows} ->
        {_, name, _, _} = hd(rows)

        services =
          for {_, _, service_id, instance_id} <- rows, not is_nil(service_id) do
            %{"id" => service_id, "instance_id" => instance_id, "type" => "dns"}
          end

        %{"id" => id, "name" => name, "services" => services}
      end)
      |> with_service_counts()
      |> Enum.sort_by(&{&1["name"], &1["id"]})

    %{
      "workers" => workers,
      "search" => search,
      "page" => page,
      "page_size" => @page_size,
      "total" => total,
      "displayed" => length(rows),
      "has_next" => page * @page_size < total
    }
  end

  # These identities are independent of the candidate page. Every selected service
  # remains available even when its Worker or service does not match the search.
  def selected(rows) do
    worker_ids = rows |> Enum.map(& &1["worker_id"]) |> Enum.uniq()
    service_ids = rows |> Enum.map(& &1["service_id"]) |> Enum.reject(&(&1 in [nil, ""]))

    services =
      Repo.all(
        from(s in Service,
          where: s.worker_id in ^worker_ids and s.id in ^service_ids and s.type == "dns",
          order_by: [s.instance_id, s.id],
          select: %{
            "id" => s.id,
            "worker_id" => s.worker_id,
            "instance_id" => s.instance_id,
            "type" => s.type
          }
        )
      )
      |> Enum.group_by(& &1["worker_id"])

    Repo.all(
      from(w in Worker,
        where: w.id in ^worker_ids,
        order_by: [w.name, w.id],
        select: %{"id" => w.id, "name" => w.name}
      )
    )
    |> Enum.map(&Map.put(&1, "services", Map.get(services, &1["id"], [])))
    |> with_service_counts()
  end

  defp with_service_counts(workers) do
    ids = Enum.map(workers, & &1["id"])

    counts =
      Repo.all(
        from(s in Service,
          where: s.worker_id in ^ids and s.type == "dns",
          group_by: s.worker_id,
          select: {s.worker_id, count(s.id)}
        )
      )
      |> Map.new()

    Enum.map(workers, &Map.put(&1, "dns_service_count", Map.get(counts, &1["id"], 0)))
  end

  defp page(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number > 0 and number <= 100_000 -> number
      _ -> 1
    end
  end

  defp page(_value), do: 1
end
