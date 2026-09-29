defmodule YellowDog.Dns.ManagedSnapshot do
  @moduledoc """
  Durable activation of the complete management-owned authoritative zone set.

  A synced pending marker preserves the previous version across interrupted
  activation. Startup resolves it before replaying the active snapshot. A
  last-valid copy repairs active-file corruption after a completed install.
  The applied marker is written only after the in-memory switch and checks.
  """

  alias DNS.Message.Record
  alias YellowDog.Dns.Zone.Auth
  alias YellowDog.Dns.ZoneController
  alias YellowDog.Dns.{View, ViewManager}
  alias YellowDog.Sync.DnsManifest

  @max_bytes 1_048_576

  def install(manifest, data_dir) when is_map(manifest) and is_binary(data_dir) do
    :global.trans({__MODULE__, Path.expand(data_dir)}, fn ->
      with :ok <- recover_pending(data_dir),
           {:ok, digest} <- DnsManifest.validate(manifest, manifest["server_id"]),
           :ok <- validate_size(manifest),
           {:ok, zones} <- build_zones(manifest),
           :ok <- check_conflicts(zones),
           {:ok, previous} <- read_active(data_dir),
           :ok <- if(previous, do: validate_committed(previous), else: :ok),
           :ok <- fence(previous, manifest, digest),
           :ok <- stage(manifest, data_dir),
           :ok <- prepare_commit(previous, data_dir) do
        case activate(zones, data_dir) do
          :ok ->
            case local_check(zones) do
              :ok ->
                case commit(data_dir) do
                  :ok ->
                    case finalize_commit(manifest, digest, data_dir) do
                      :ok -> {:ok, %{"generation" => manifest["generation"], "digest" => digest}}
                      error -> abort_install(previous, zones, data_dir, error)
                    end

                  error ->
                    abort_install(previous, zones, data_dir, error)
                end

              error ->
                abort_install(previous, zones, data_dir, error)
            end

          error ->
            abort_install(previous, zones, data_dir, error)
        end
      end
    end)
  end

  def install(_, _), do: {:error, :invalid_manifest}

  def managed_zone?(apex, data_dir) when is_binary(apex) and is_binary(data_dir) do
    case read_active(data_dir) do
      {:ok, %{"zones" => zones}} when is_list(zones) ->
        Enum.any?(zones, fn zone -> is_map(zone) and zone["apex"] == apex end)

      {:ok, nil} ->
        false

      {:error, _} ->
        File.exists?(active_path(data_dir))

      _ ->
        true
    end
  end

  @doc "Returns committed records for a managed zone process restarting under its supervisor."
  def recover_zone_data(apex, data_dir) do
    with {:ok, active} <- read_active(data_dir),
         :ok <- if(active, do: validate_committed(active), else: :ok),
         {:ok, zones} <- if(active, do: build_zones(active), else: {:ok, []}) do
      case List.keyfind(zones, apex, 0) do
        {^apex, records} -> {:ok, records}
        nil -> {:ok, nil}
      end
    end
  end

  defp validate_committed(manifest) do
    case DnsManifest.validate(manifest, manifest["server_id"]) do
      {:ok, _digest} -> :ok
      error -> error
    end
  end

  def installed_status(data_dir) do
    with false <- File.exists?(pending_path(data_dir)),
         {:ok, active} <- read_active(data_dir),
         {:ok, active_digest} <- DnsManifest.digest(active),
         {:ok, marker} <- read_json(applied_path(data_dir)),
         true <- marker["generation"] == active["generation"],
         true <- marker["digest"] == active_digest,
         true <- Process.whereis(ZoneController) != nil,
         {:ok, zones} <- build_zones(active),
         :ok <- local_check(zones) do
      {:ok, marker}
    else
      _ -> {:ok, nil}
    end
  end

  def recover(data_dir) do
    :global.trans({__MODULE__, Path.expand(data_dir)}, fn -> do_recover(data_dir) end)
  end

  defp do_recover(data_dir) do
    with :ok <- recover_pending(data_dir) do
      recover_active(data_dir)
    end
  end

  defp recover_active(data_dir) do
    case read_recoverable_active(data_dir) do
      {:ok, nil} ->
        :ok

      {:ok, manifest} ->
        with {:ok, digest} <- DnsManifest.validate(manifest, manifest["server_id"]),
             {:ok, zones} <- build_zones(manifest),
             :ok <- check_conflicts(zones),
             :ok <- invalidate_applied(data_dir),
             :ok <- activate(zones, data_dir),
             :ok <- local_check(zones),
             :ok <- write_applied(manifest, digest, data_dir) do
          :ok
        end

      error ->
        error
    end
  end

  defp validate_size(manifest) do
    if byte_size(Jason.encode!(manifest)) <= @max_bytes,
      do: :ok,
      else: {:error, :manifest_too_large}
  end

  defp build_zones(%{"zones" => zones}) when is_list(zones) do
    Enum.reduce_while(zones, {:ok, []}, fn zone, {:ok, acc} ->
      with {:ok, expected} <- DnsManifest.zone_digest(zone),
           true <- zone["digest"] == expected,
           {:ok, records} <- build_records(zone) do
        {:cont, {:ok, [{zone["apex"], records} | acc]}}
      else
        _ -> {:halt, {:error, :invalid_zone_snapshot}}
      end
    end)
    |> case do
      {:ok, built} -> {:ok, Enum.reverse(built)}
      error -> error
    end
  end

  defp build_zones(_), do: {:error, :invalid_manifest}

  defp build_records(%{"apex" => apex, "rrsets" => rrsets}) when is_list(rrsets) do
    try do
      records =
        for %{"owner" => owner, "type" => type, "ttl" => ttl, "records" => values} <- rrsets,
            value <- values do
          data =
            case {type, value} do
              {"A", ip} when is_binary(ip) ->
                {:ok, tuple} = ip |> String.to_charlist() |> :inet.parse_ipv4_address()
                tuple

              {"AAAA", ip} when is_binary(ip) ->
                {:ok, tuple} = ip |> String.to_charlist() |> :inet.parse_ipv6_address()
                tuple

              {"NS", host} when is_binary(host) ->
                host

              {"CNAME", host} when is_binary(host) ->
                host

              {"MX", %{"preference" => preference, "exchange" => exchange}} ->
                {preference, exchange}

              {"TXT", segments} when is_list(segments) ->
                segments

              {"SOA",
               %{
                 "mname" => m,
                 "rname" => r,
                 "serial" => s,
                 "refresh" => f,
                 "retry" => retry,
                 "expire" => e,
                 "minimum" => min
               }} ->
                {m, r, s, f, retry, e, min}
            end

          Record.new(owner, String.downcase(type) |> String.to_existing_atom(), :in, ttl, data)
        end

      soa = Enum.count(records, &(&1.type.value == <<0, 6>> and to_string(&1.name) == apex))
      ns = Enum.count(records, &(&1.type.value == <<0, 2>> and to_string(&1.name) == apex))

      if soa == 1 and ns > 0 and length(records) > 0,
        do: {:ok, records},
        else: {:error, :invalid_apex}
    rescue
      _ -> {:error, :invalid_record}
    catch
      _, _ -> {:error, :invalid_record}
    end
  end

  defp build_records(_), do: {:error, :invalid_record}

  defp check_conflicts(zones) do
    Enum.reduce_while(zones, :ok, fn {apex, _}, _ ->
      case ZoneController.find_zone("default", :auth, apex) do
        {:ok, pid} ->
          if Auth.managed?(pid),
            do: {:cont, :ok},
            else: {:halt, {:error, :unmanaged_zone_conflict}}

        :error ->
          {:cont, :ok}
      end
    end)
  end

  defp fence(nil, _manifest, _digest), do: :ok

  defp fence(previous, manifest, digest) do
    old = previous["generation"]

    cond do
      manifest["generation"] < old ->
        {:error, :stale_generation}

      manifest["generation"] == old ->
        case DnsManifest.digest(previous) do
          {:ok, ^digest} -> :ok
          _ -> {:error, :generation_conflict}
        end

      true ->
        :ok
    end
  end

  defp activate(zones, data_dir) do
    Enum.reduce_while(zones, :ok, fn {apex, records}, _ ->
      result =
        case ZoneController.find_zone("default", :auth, apex) do
          {:ok, pid} ->
            Auth.activate_managed(pid, records)

          :error ->
            case ZoneController.start_zone(:auth, apex,
                   managed: true,
                   managed_data_dir: data_dir,
                   zone_data: records
                 ) do
              {:ok, _pid} -> :ok
              error -> error
            end
        end

      result = if result == :ok, do: register_view(apex), else: result
      if result == :ok, do: {:cont, :ok}, else: {:halt, {:error, {:activation_failed, result}}}
    end)
  end

  defp register_view(apex) do
    if Process.whereis(ViewManager) do
      case ViewManager.get_view("default") do
        {:ok, pid} -> View.register_zone(pid, :auth, apex)
        :error -> {:error, :default_view_unavailable}
      end
    else
      :ok
    end
  end

  defp unregister_view(apex) do
    if Process.whereis(ViewManager) do
      case ViewManager.get_view("default") do
        {:ok, pid} -> View.unregister_zone(pid, :auth, apex)
        :error -> :ok
      end
    end
  end

  defp local_check(zones) do
    Enum.reduce_while(zones, :ok, fn {apex, records}, _ ->
      case ZoneController.find_zone("default", :auth, apex) do
        {:ok, pid} ->
          actual = Auth.get_all_records(pid)

          checks =
            Enum.uniq(for record <- records, do: {to_string(record.name), record_type(record)})

          if view_routes_zone?(apex) and Enum.sort(actual) == Enum.sort(records) and
               Enum.all?(checks, fn {owner, type} -> check_answer(owner, type) end),
             do: {:cont, :ok},
             else: {:halt, {:error, :local_check_failed}}

        :error ->
          {:halt, {:error, :local_check_failed}}
      end
    end)
  end

  defp record_type(%Record{type: %{value: <<code::16>>}}) do
    case code do
      1 -> :a
      2 -> :ns
      5 -> :cname
      6 -> :soa
      15 -> :mx
      16 -> :txt
      28 -> :aaaa
    end
  end

  defp view_routes_zone?(apex) do
    case ViewManager.get_view("default") do
      {:ok, view} ->
        stats = View.stats(view)
        stats.enabled and Enum.member?(stats.zones, {:auth, apex})

      :error ->
        false
    end
  end

  defp check_answer(owner, type) do
    query = %DNS.Message{
      header: %DNS.Message.Header{id: 1, rd: false},
      qdlist: [%{name: owner, type: type, class: :in}],
      anlist: [],
      nslist: [],
      arlist: []
    }

    case ViewManager.get_view("default") do
      {:ok, view} ->
        case View.resolve(view, self(), 1, query) do
          {:ok, response} -> response.header.aa in [1, true] and response.anlist != []
          _ -> false
        end

      :error ->
        false
    end
  end

  defp stage(manifest, data_dir) do
    path = active_path(data_dir)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- synced_write(path <> ".candidate", Jason.encode!(manifest)) do
      :ok
    end
  end

  defp commit(data_dir) do
    path = active_path(data_dir)

    with :ok <- File.rename(path <> ".candidate", path),
         :ok <- sync_dir(Path.dirname(path)),
         do: :ok
  end

  defp prepare_commit(previous, data_dir) do
    pending = pending_path(data_dir)

    with :ok <- synced_write(pending <> ".candidate", Jason.encode!(%{"previous" => previous})),
         :ok <- File.rename(pending <> ".candidate", pending),
         :ok <- sync_dir(Path.dirname(pending)) do
      :ok
    end
  end

  defp finalize_commit(manifest, digest, data_dir) do
    with :ok <- restore_last_valid(manifest, data_dir),
         :ok <- write_applied(manifest, digest, data_dir),
         :ok <- remove_synced(pending_path(data_dir)) do
      :ok
    end
  end

  defp recover_pending(data_dir) do
    case read_json(pending_path(data_dir)) do
      {:error, :enoent} ->
        :ok

      {:ok, %{"previous" => previous} = marker} when map_size(marker) == 1 ->
        with :ok <- validate_previous(previous),
             :ok <- invalidate_applied(data_dir),
             :ok <- restore_active(previous, data_dir),
             :ok <- restore_last_valid(previous, data_dir),
             :ok <- remove_synced(pending_path(data_dir)) do
          :ok
        end

      _ ->
        {:error, :corrupt_pending_snapshot}
    end
  end

  defp validate_previous(nil), do: :ok
  defp validate_previous(previous) when is_map(previous), do: validate_committed(previous)
  defp validate_previous(_), do: {:error, :corrupt_pending_snapshot}

  defp abort_install(previous, zones, data_dir, error) do
    recovered = recover_pending(data_dir)
    rolled_back = rollback(previous, zones, data_dir)

    case {recovered, rolled_back} do
      {:ok, :ok} -> error
      failures -> {:error, {:install_abort_failed, error, failures}}
    end
  end

  defp restore_active(nil, data_dir), do: remove_synced(active_path(data_dir))

  defp restore_active(previous, data_dir) do
    path = active_path(data_dir)

    with :ok <- synced_write(path <> ".rollback", Jason.encode!(previous)),
         :ok <- File.rename(path <> ".rollback", path),
         :ok <- sync_dir(Path.dirname(path)),
         do: :ok
  end

  defp restore_last_valid(nil, data_dir), do: remove_synced(last_valid_path(data_dir))

  defp restore_last_valid(previous, data_dir) do
    path = last_valid_path(data_dir)

    with :ok <- synced_write(path <> ".candidate", Jason.encode!(previous)),
         :ok <- File.rename(path <> ".candidate", path),
         :ok <- sync_dir(Path.dirname(path)) do
      :ok
    end
  end

  defp rollback(nil, zones, _data_dir) do
    Enum.reduce_while(zones, :ok, fn {apex, _records}, _ ->
      result =
        case ZoneController.find_zone("default", :auth, apex) do
          {:ok, pid} ->
            if Auth.managed?(pid), do: ZoneController.stop_zone("default", :auth, apex)

          :error ->
            :ok
        end

      if result == :ok do
        unregister_view(apex)
        {:cont, :ok}
      else
        {:halt, result}
      end
    end)
  end

  defp rollback(previous, new_zones, data_dir) do
    with {:ok, prior_zones} <- build_zones(previous),
         :ok <- activate(prior_zones, data_dir) do
      prior_names = MapSet.new(Enum.map(prior_zones, &elem(&1, 0)))

      Enum.reduce_while(new_zones, :ok, fn {apex, _}, _ ->
        if MapSet.member?(prior_names, apex) do
          {:cont, :ok}
        else
          case ZoneController.find_zone("default", :auth, apex) do
            :error ->
              {:cont, :ok}

            {:ok, _pid} ->
              case ZoneController.stop_zone("default", :auth, apex) do
                :ok ->
                  unregister_view(apex)
                  {:cont, :ok}

                error ->
                  {:halt, error}
              end
          end
        end
      end)
    end
  end

  defp write_applied(manifest, digest, data_dir) do
    marker = %{"generation" => manifest["generation"], "digest" => digest}
    path = applied_path(data_dir)

    with :ok <- synced_write(path <> ".candidate", Jason.encode!(marker)),
         :ok <- File.rename(path <> ".candidate", path),
         :ok <- sync_dir(Path.dirname(path)) do
      :ok
    end
  end

  defp invalidate_applied(data_dir) do
    remove_synced(applied_path(data_dir))
  end

  defp remove_synced(path) do
    case File.rm(path) do
      :ok -> sync_dir(Path.dirname(path))
      {:error, :enoent} -> :ok
      error -> error
    end
  end

  defp synced_write(path, content) do
    with {:ok, file} <- :file.open(String.to_charlist(path), [:write, :binary, :raw]) do
      result = with :ok <- :file.write(file, content), do: :file.sync(file)
      :ok = :file.close(file)
      result
    end
  end

  defp sync_dir(dir) do
    case System.find_executable("sync") do
      nil ->
        {:error, :sync_unavailable}

      executable ->
        case System.cmd(executable, ["-f", dir], stderr_to_stdout: true) do
          {_, 0} -> :ok
          {output, _} -> {:error, {:directory_sync_failed, output}}
        end
    end
  end

  defp read_active(data_dir) do
    case read_json(active_path(data_dir)) do
      {:error, :enoent} -> {:ok, nil}
      result -> result
    end
  end

  defp read_recoverable_active(data_dir) do
    case read_active(data_dir) do
      {:ok, nil} ->
        if File.exists?(last_valid_path(data_dir)),
          do: restore_from_last_valid(data_dir),
          else: {:ok, nil}

      {:ok, manifest} = result ->
        if validate_committed(manifest) == :ok do
          result
        else
          restore_from_last_valid(data_dir)
        end

      {:error, _} ->
        restore_from_last_valid(data_dir)
    end
  end

  defp restore_from_last_valid(data_dir) do
    with {:ok, previous} <- read_json(last_valid_path(data_dir)),
         :ok <- validate_committed(previous),
         :ok <- restore_active(previous, data_dir) do
      {:ok, previous}
    end
  end

  defp read_json(path) do
    with {:ok, bytes} <- File.read(path),
         true <- byte_size(bytes) <= @max_bytes,
         {:ok, map} when is_map(map) <- Jason.decode(bytes) do
      {:ok, map}
    else
      false -> {:error, :snapshot_too_large}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :corrupt_snapshot}
    end
  end

  defp active_path(data_dir), do: Path.join([data_dir, "managed_dns", "active.json"])
  defp applied_path(data_dir), do: Path.join([data_dir, "managed_dns", "applied.json"])
  defp pending_path(data_dir), do: Path.join([data_dir, "managed_dns", "pending.json"])
  defp last_valid_path(data_dir), do: Path.join([data_dir, "managed_dns", "last_valid.json"])
end
