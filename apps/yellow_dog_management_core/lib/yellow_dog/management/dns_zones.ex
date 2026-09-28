defmodule YellowDog.Management.DnsZones do
  @moduledoc "Durable management-owned drafts, publications and DNS desired state."

  use GenServer

  alias YellowDog.Management.DnsZone
  alias YellowDog.Management.Servers
  alias YellowDog.Management.Storage.AtomicJson
  alias YellowDog.Management.Storage.Path, as: StoragePath

  @empty %{
    "schema_version" => 1,
    "zones" => %{},
    "deployments" => %{},
    "generations" => %{},
    "idempotency" => %{}
  }

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def list, do: GenServer.call(__MODULE__, :list)
  def get(id), do: GenServer.call(__MODULE__, {:get, id})
  def deployment(id), do: GenServer.call(__MODULE__, {:deployment, id})
  def manifest(server_id), do: GenServer.call(__MODULE__, {:manifest, server_id})

  def create(attrs, actor \\ "api", key \\ nil),
    do: GenServer.call(__MODULE__, {:create, attrs, actor, key})

  def edit(id, revision, edits, actor \\ "api", key \\ nil),
    do: GenServer.call(__MODULE__, {:edit, id, revision, edits, actor, key})

  def publish(id, revision, actor, key),
    do: GenServer.call(__MODULE__, {:publish, id, revision, actor, key})

  def report_applied(server_id, generation, digest),
    do: report_state(server_id, generation, digest, "applied", nil)

  def report_failed(server_id, generation, digest, error),
    do: report_state(server_id, generation, digest, "failed", error)

  defp report_state(server_id, generation, digest, status, error),
    do: GenServer.call(__MODULE__, {:observed, server_id, generation, digest, status, error})

  @impl true
  def init(_opts) do
    {:ok, path} = StoragePath.root()
    path = Path.join([path, "dns", "state.json"])

    state =
      case AtomicJson.read(path) do
        {:ok,
         %{
           "schema_version" => 1,
           "zones" => zones,
           "deployments" => deployments,
           "generations" => generations
         } = state}
        when is_map(zones) and is_map(deployments) and is_map(generations) ->
          Map.put_new(state, "idempotency", %{})

        {:error, %YellowDog.Sync.Error{code: :not_found}} ->
          @empty

        _ ->
          raise "managed DNS state is unreadable; refusing to start with empty state"
      end

    {:ok, {path, state}}
  end

  @impl true
  def handle_call(:list, _from, {_, state} = server_state) do
    zones = state["zones"] |> Map.values() |> Enum.sort_by(& &1["apex"]) |> Enum.take(100)
    {:reply, zones, server_state}
  end

  def handle_call({:get, id}, _from, {_, state} = server_state),
    do: {:reply, fetch(state["zones"], id), server_state}

  def handle_call({:deployment, id}, _from, {_, state} = server_state),
    do: {:reply, fetch(state["deployments"], id), server_state}

  def handle_call({:manifest, server_id}, _from, {_, state} = server_state) do
    {:reply, build_manifest(state, server_id), server_state}
  end

  def handle_call({:create, attrs, actor, key}, _from, {path, state} = server_state) do
    identity = {"#{actor}:create:#{key}", DnsZone.digest(attrs)}

    result =
      case idempotency(state, identity, key) do
        :new ->
          with %{"apex" => apex, "targets" => targets} <- attrs,
               {:ok, apex} <- DnsZone.name(apex),
               :ok <- valid_targets(targets),
               true <- map_size(state["zones"]) < 100,
               false <- Enum.any?(state["zones"], fn {_, zone} -> zone["apex"] == apex end),
               {:ok, rrsets} <- DnsZone.normalize_rrsets(apex, Map.get(attrs, "rrsets", [])) do
            id = uuid()

            zone = %{
              "id" => id,
              "apex" => apex,
              "targets" => Enum.sort(targets),
              "revision" => 1,
              "rrsets" => rrsets,
              "published_version" => nil,
              "soa_serial" => 0,
              "versions" => []
            }

            next = state |> put_in(["zones", id], zone) |> remember(identity, key, zone)
            persist(path, next, {:ok, zone}, server_state)
          else
            false -> {:error, :conflict}
            nil -> {:error, :invalid_zone}
            {:error, _} = error -> error
            _ -> {:error, :invalid_zone}
          end

        replay ->
          replay
      end

    reply(result, server_state)
  end

  def handle_call({:edit, id, revision, edits, actor, key}, _from, {path, state} = server_state) do
    identity =
      {"#{actor}:edit:#{key}",
       DnsZone.digest(%{"id" => id, "revision" => revision, "edits" => edits})}

    result =
      case idempotency(state, identity, key) do
        :new ->
          with {:ok, zone} <- fetch(state["zones"], id),
               :ok <- expected_revision(zone, revision),
               true <- is_list(edits) and length(edits) in 1..100,
               {:ok, rrsets} <- apply_edits(zone, edits) do
            updated = %{zone | "revision" => revision + 1, "rrsets" => rrsets}
            next = state |> put_in(["zones", id], updated) |> remember(identity, key, updated)
            persist(path, next, {:ok, updated}, server_state)
          else
            false -> {:error, :invalid_edits}
            {:error, _} = error -> error
            _ -> {:error, :invalid_edits}
          end

        replay ->
          replay
      end

    reply(result, server_state)
  end

  def handle_call({:publish, id, revision, actor, key}, _from, {path, state} = server_state) do
    identity = "#{actor}:publish:#{key}"
    request = DnsZone.digest(%{"zone_id" => id, "revision" => revision})

    result =
      case idempotency(state, {identity, request}, key) do
        :new ->
          do_publish(path, state, server_state, id, revision, identity, request)

        replay ->
          replay
      end

    reply(result, server_state)
  end

  def handle_call(
        {:observed, server_id, generation, digest, status, error},
        _from,
        {path, state} = server_state
      ) do
    result =
      with {:ok, manifest} <- build_manifest(state, server_id),
           true <- manifest["generation"] == generation,
           {:ok, ^digest} <- YellowDog.Sync.DnsManifest.digest(manifest) do
        deployments =
          Map.new(state["deployments"], fn {id, deployment} ->
            target = get_in(deployment, ["targets", server_id])

            if target && target["generation"] == generation do
              installed =
                if status == "applied" do
                  %{
                    "zone_version" => deployment["zone_version"],
                    "zone_digest" => deployment["zone_digest"]
                  }
                else
                  %{"zone_version" => nil, "zone_digest" => nil}
                end

              {id,
               put_in(
                 deployment,
                 ["targets", server_id, "observed"],
                 Map.merge(installed, %{
                   "generation" => generation,
                   "digest" => digest,
                   "state" => status,
                   "error" => error
                 })
               )}
            else
              {id, deployment}
            end
          end)

        deployments =
          Map.new(deployments, fn {id, deployment} ->
            applied? =
              Enum.all?(deployment["targets"], fn {_, target} ->
                get_in(target, ["observed", "state"]) == "applied"
              end)

            failed? =
              Enum.any?(deployment["targets"], fn {_, target} ->
                get_in(target, ["observed", "state"]) == "failed"
              end)

            state =
              cond do
                applied? -> "applied"
                failed? -> "failed"
                true -> "accepted"
              end

            {id, Map.put(deployment, "state", state)}
          end)

        if deployments == state["deployments"] do
          :ok
        else
          persist(path, %{state | "deployments" => deployments}, :ok, server_state)
        end
      else
        _ -> {:error, :conflict}
      end

    reply(result, server_state)
  end

  defp do_publish(path, state, server_state, id, revision, identity, request) do
    with {:ok, zone} <- fetch(state["zones"], id),
         :ok <- expected_revision(zone, revision),
         :ok <- DnsZone.validate_complete(zone["apex"], zone["rrsets"]) do
      version = length(zone["versions"]) + 1
      serial = zone["soa_serial"] + 1
      snapshot = DnsZone.snapshot(zone, version, serial)

      generations =
        Enum.reduce(
          zone["targets"],
          state["generations"],
          &Map.update(&2, &1, 1, fn n -> n + 1 end)
        )

      targets =
        Map.new(zone["targets"], fn server_id ->
          {server_id,
           %{"generation" => generations[server_id], "observed" => nil, "verification" => nil}}
        end)

      deployment = %{
        "id" => uuid(),
        "zone_id" => id,
        "draft_revision" => revision,
        "zone_version" => version,
        "zone_digest" => snapshot["digest"],
        "soa_serial" => serial,
        "targets" => targets,
        "idempotency_identity" => identity,
        "request_digest" => request,
        "state" => "accepted"
      }

      updated = %{
        zone
        | "published_version" => version,
          "soa_serial" => serial,
          "versions" => zone["versions"] ++ [snapshot]
      }

      next =
        state
        |> put_in(["zones", id], updated)
        |> put_in(["deployments", deployment["id"]], deployment)
        |> Map.put("generations", generations)

      with {:ok, next} <- add_expected_digests(next, zone["targets"], deployment["id"]) do
        result = get_in(next, ["deployments", deployment["id"]])
        next = remember(next, {identity, request}, "publish", result)
        persist(path, next, {:ok, result}, server_state)
      end
    else
      error -> error
    end
  end

  defp apply_edits(zone, edits) do
    Enum.reduce_while(edits, {:ok, zone["rrsets"]}, fn edit, {:ok, current} ->
      with %{"owner" => owner, "type" => type} <- edit,
           {:ok, owner} <- DnsZone.name(owner),
           true <- owner == zone["apex"] or String.ends_with?(owner, "." <> zone["apex"]),
           true <- type in ~w(A NS SOA) do
        current = Enum.reject(current, &(&1["owner"] == owner and &1["type"] == type))

        next =
          if edit["delete"] == true do
            current
          else
            [Map.take(edit, ~w(owner type ttl records)) | current]
          end

        case DnsZone.normalize_rrsets(zone["apex"], next) do
          {:ok, normalized} -> {:cont, {:ok, normalized}}
          error -> {:halt, error}
        end
      else
        _ -> {:halt, {:error, :invalid_edits}}
      end
    end)
  end

  defp add_expected_digests(state, targets, deployment_id) do
    Enum.reduce_while(targets, {:ok, state}, fn server_id, {:ok, acc} ->
      with {:ok, manifest} <- build_manifest(acc, server_id),
           {:ok, digest} <- YellowDog.Sync.DnsManifest.digest(manifest) do
        next =
          put_in(
            acc,
            ["deployments", deployment_id, "targets", server_id, "expected_digest"],
            digest
          )

        {:cont, {:ok, next}}
      else
        _ -> {:halt, {:error, :too_large}}
      end
    end)
  end

  defp build_manifest(state, server_id) do
    with {:ok, _server} <- Servers.get(server_id) do
      zones =
        state["zones"]
        |> Map.values()
        |> Enum.filter(&(server_id in &1["targets"] and &1["published_version"] != nil))
        |> Enum.map(fn zone -> List.last(zone["versions"]) end)
        |> Enum.sort_by(& &1["apex"])

      {:ok,
       %{
         "schema_version" => 1,
         "server_id" => server_id,
         "generation" => Map.get(state["generations"], server_id, 0),
         "zones" => zones
       }}
    end
  end

  defp valid_targets(targets) when is_list(targets) and length(targets) in 1..16 do
    if length(Enum.uniq(targets)) == length(targets) and
         Enum.all?(targets, fn id -> is_binary(id) and match?({:ok, _}, Servers.get(id)) end) do
      :ok
    else
      {:error, :unknown_target}
    end
  end

  defp valid_targets(_), do: {:error, :invalid_targets}

  defp expected_revision(%{"revision" => revision}, revision), do: :ok
  defp expected_revision(_, _), do: {:error, :conflict}

  defp idempotency(_state, _identity, nil), do: :new

  defp idempotency(_state, _identity, key)
       when not is_binary(key) or byte_size(key) not in 1..128,
       do: {:error, :invalid_idempotency_key}

  defp idempotency(state, {id, digest}, _key) do
    case get_in(state, ["idempotency", id]) do
      nil -> :new
      %{"digest" => ^digest, "result" => result} -> {:ok, result}
      _ -> {:error, :conflict}
    end
  end

  defp remember(state, _identity, nil, _result), do: state

  defp remember(state, {id, digest}, _key, result),
    do: put_in(state, ["idempotency", id], %{"digest" => digest, "result" => result})

  defp persist(path, state, result, _old) do
    case AtomicJson.replace(path, state) do
      {:ok, _} -> {result, {path, state}}
      error -> error
    end
  end

  defp reply({result, {path, state} = new_state}, _old) when is_binary(path) and is_map(state),
    do: {:reply, result, new_state}

  defp reply(result, old), do: {:reply, result, old}

  defp fetch(map, id) do
    case Map.fetch(map, id) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, :not_found}
    end
  end

  defp uuid do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end
