defmodule YellowDog.Management.ZoneCatalog do
  @moduledoc "Bounded, metadata-only reads for the global Zone catalog."
  import Ecto.Query
  alias YellowDog.Management.{Assignment, Repo, ResourceVersion, Rrset, Service, Zone}

  def list(options \\ %{}) do
    search = options["search"]
    page = positive_integer(options["page"], 1, 100_000)
    size = positive_integer(options["page_size"], 20, 100)
    sort = if options["sort"] == "revision", do: :revision, else: :name
    search = if is_binary(search), do: String.slice(search, 0, 253), else: ""
    query = from(z in Zone, where: is_nil(z.deleted_at))

    query =
      if search == "",
        do: query,
        else: from(z in query, where: fragment("strpos(lower(?), lower(?)) > 0", z.name, ^search))

    total = Repo.aggregate(from(z in Zone, where: is_nil(z.deleted_at)), :count)
    matching_total = Repo.aggregate(query, :count)

    query =
      if sort == :revision,
        do: from(z in query, order_by: [desc: z.revision, asc: z.name, asc: z.id]),
        else: from(z in query, order_by: [asc: z.name, asc: z.id])

    zones =
      Repo.all(
        from(z in query,
          limit: ^size,
          offset: ^((page - 1) * size),
          select: %{id: z.id, name: z.name, revision: z.revision}
        )
      )

    ids = Enum.map(zones, & &1.id)

    versions =
      Repo.all(
        from(v in ResourceVersion,
          where: v.zone_id in ^ids,
          group_by: v.zone_id,
          select: {v.zone_id, max(v.version)}
        )
      )
      |> Map.new()

    records =
      Repo.all(
        from(r in Rrset,
          where: r.zone_id in ^ids,
          group_by: r.zone_id,
          select: {r.zone_id, sum(fragment("cardinality(?)", r.data))}
        )
      )
      |> Map.new()

    usage =
      Repo.all(
        from(a in Assignment,
          join: s in Service,
          on: s.id == a.service_id,
          where: a.zone_id in ^ids,
          group_by: a.zone_id,
          select: {a.zone_id, count(a.id), count(s.worker_id, :distinct)}
        )
      )
      |> Map.new(fn {id, services, workers} -> {id, {services, workers}} end)

    rows =
      Enum.map(zones, fn z ->
        {services, workers} = Map.get(usage, z.id, {0, 0})

        %{
          "id" => z.id,
          "name" => z.name,
          "revision" => z.revision,
          "record_count" => Map.get(records, z.id, 0),
          "latest_version" => versions[z.id],
          "service_count" => services,
          "worker_count" => workers
        }
      end)

    %{
      "zones" => rows,
      "total" => total,
      "page" => page,
      "page_size" => size,
      "search" => search,
      "sort" => to_string(sort),
      "matching_total" => matching_total,
      "has_next" => page * size < matching_total
    }
  end

  defp positive_integer(value, default, maximum) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n > 0 and n <= maximum -> n
      _ -> default
    end
  end

  defp positive_integer(value, _default, maximum)
       when is_integer(value) and value > 0 and value <= maximum,
       do: value

  defp positive_integer(_value, default, _maximum), do: default
end
