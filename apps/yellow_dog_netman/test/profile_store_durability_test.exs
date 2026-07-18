defmodule YellowDog.Netman.ProfileStoreDurabilityTest.FileOps do
  @moduledoc false

  @config_key :profile_store_durability_file_ops

  def configure(owner, fail_at \\ nil) do
    Application.put_env(:yellow_dog_netman, @config_key, %{owner: owner, fail_at: fail_at})
  end

  def mkdir_p(path), do: run(:mkdir_p, [path], fn -> File.mkdir_p(path) end)

  def open(path),
    do: run(:open, [path], fn -> :file.open(path, [:write, :exclusive, :binary, :raw]) end)

  def write(device, contents),
    do: run(:write, [byte_size(contents)], fn -> :file.write(device, contents) end)

  def sync(device), do: run(:sync, [], fn -> :file.sync(device) end)
  def close(device), do: run(:close, [], fn -> :file.close(device) end)

  def rename(source, target),
    do: run(:rename, [source, target], fn -> File.rename(source, target) end)

  def rm(path), do: run(:rm, [path], fn -> File.rm(path) end)

  def sync_dir(directory) do
    run(:sync_dir, [directory], fn ->
      with {:ok, device} <- :file.open(directory, [:read, :raw, :directory]) do
        result =
          case :file.sync(device) do
            {:error, :enotsup} -> :ok
            other -> other
          end

        close_result = :file.close(device)

        case {result, close_result} do
          {:ok, :ok} -> :ok
          {{:error, reason}, _} -> {:error, reason}
          {:ok, {:error, reason}} -> {:error, reason}
        end
      else
        {:error, :enotsup} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp run(operation, details, callback) do
    %{owner: owner, fail_at: fail_at} =
      Application.fetch_env!(:yellow_dog_netman, @config_key)

    send(owner, {:profile_store_file_op, operation, details})

    case fail_at do
      ^operation -> {:error, :injected_failure}
      {:raise, ^operation} -> raise "injected failure"
      {:exit, ^operation} -> exit(:injected_failure)
      _other -> callback.()
    end
  end
end

defmodule YellowDog.Netman.ProfileStoreDurabilityTest do
  use ExUnit.Case, async: false

  alias YellowDog.Netman.ProfileStore
  alias YellowDog.Netman.ProfileStoreDurabilityTest.FileOps
  alias YellowDog.Netman.Types.Profile

  setup do
    profile_dir =
      Path.join(
        System.tmp_dir!(),
        "netman-profile-store-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(profile_dir)
    FileOps.configure(self())

    on_exit(fn ->
      Application.delete_env(:yellow_dog_netman, :profile_store_durability_file_ops)
      File.rm_rf!(profile_dir)
    end)

    {:ok, profile_dir: profile_dir}
  end

  test "put writes canonical TOML atomically before publishing and survives restart", %{
    profile_dir: profile_dir
  } do
    {:ok, store} = start_store(profile_dir)
    profile = profile("durable-profile", interface: "eth7", priority: 70)
    path = profile_path(profile_dir, profile.id)

    YellowDog.Netman.EventBus.subscribe("netman:profile:changed")

    assert :ok = put(store, profile.id, profile)
    assert File.regular?(path)
    assert {:ok, ^profile} = get(store, profile.id)
    assert {:ok, revision} = revision(store, profile.id)
    assert revision =~ ~r/\A[0-9a-f]{64}\z/

    assert_receive {:netman_event, "netman:profile:changed", {:updated, "durable-profile"}}

    assert {:ok, encoded} = File.read(path)
    assert {:ok, decoded} = Toml.decode(encoded)
    assert {:ok, ^profile} = Profile.from_toml(decoded)

    operations = drain_file_operations()
    assert_ordered(operations, [:mkdir_p, :open, :write, :sync, :close, :rename, :sync_dir])

    assert {:rename, [temporary_path, ^path]} =
             Enum.find(operations, fn {operation, _details} -> operation == :rename end)

    assert Path.dirname(temporary_path) == profile_dir

    GenServer.stop(store)
    {:ok, restarted} = start_store(profile_dir)

    assert {:ok, ^profile} = get(restarted, profile.id)
    assert {:ok, ^revision} = revision(restarted, profile.id)
  end

  test "put atomically replaces an existing profile and changes its revision", %{
    profile_dir: profile_dir
  } do
    {:ok, store} = start_store(profile_dir)
    original = profile("replace-profile", priority: 10)
    replacement = profile("replace-profile", priority: 20)

    assert :ok = put(store, original.id, original)
    assert {:ok, original_revision} = revision(store, original.id)
    _operations = drain_file_operations()

    assert :ok =
             put(store, replacement.id, replacement, expected_revision: original_revision)

    assert {:ok, replacement_revision} = revision(store, replacement.id)
    refute replacement_revision == original_revision
    assert {:ok, ^replacement} = get(store, replacement.id)

    operations = drain_file_operations()

    assert {:rename, [temporary_path, target_path]} =
             Enum.find(operations, fn {operation, _details} -> operation == :rename end)

    assert Path.dirname(temporary_path) == Path.dirname(target_path)
    assert target_path == profile_path(profile_dir, replacement.id)
  end

  test "canonical mutation wins over a legacy filename after restart", %{
    profile_dir: profile_dir
  } do
    original = profile("canonical-wins", priority: 10)
    replacement = profile("canonical-wins", priority: 20)
    legacy_path = Path.join(profile_dir, "z-legacy-profile.toml")

    File.write!(legacy_path, Profile.canonical_toml(original))
    {:ok, store} = start_store(profile_dir)

    assert {:ok, ^original} = get(store, original.id)
    assert :ok = put(store, replacement.id, replacement)
    GenServer.stop(store)

    {:ok, restarted} = start_store(profile_dir)
    assert {:ok, ^replacement} = get(restarted, replacement.id)
  end

  test "delete removes managed files and preserves an imported source", %{
    profile_dir: profile_dir
  } do
    {:ok, store} = start_store(profile_dir)
    imported = profile("imported-source", priority: 10)
    replacement = profile("imported-source", priority: 20)
    external_dir = profile_dir <> "-external"
    external_path = Path.join(external_dir, "source.toml")
    canonical_path = profile_path(profile_dir, imported.id)

    File.mkdir_p!(external_dir)
    File.write!(external_path, Profile.canonical_toml(imported))
    on_exit(fn -> File.rm_rf!(external_dir) end)

    assert {:ok, ^imported} = import_file(store, external_path)
    assert :ok = put(store, replacement.id, replacement)
    assert {:ok, current_revision} = revision(store, replacement.id)

    assert :ok = delete(store, replacement.id, expected_revision: current_revision)
    assert File.regular?(external_path)
    refute File.exists?(canonical_path)
    assert {:error, :not_found} = get(store, replacement.id)
  end

  test "delete removes legacy in-directory aliases so they cannot resurrect on restart", %{
    profile_dir: profile_dir
  } do
    profile = profile("legacy-delete")
    legacy_path = Path.join(profile_dir, "legacy-name.toml")

    File.write!(legacy_path, Profile.canonical_toml(profile))
    {:ok, store} = start_store(profile_dir)
    assert {:ok, current_revision} = revision(store, profile.id)

    assert :ok = delete(store, profile.id, expected_revision: current_revision)
    refute File.exists?(legacy_path)
    assert {:error, :not_found} = get(store, profile.id)

    GenServer.stop(store)
    {:ok, restarted} = start_store(profile_dir)
    assert {:error, :not_found} = get(restarted, profile.id)
  end

  test "canonical revisions are stable for equivalent profiles", %{profile_dir: profile_dir} do
    {:ok, store} = start_store(profile_dir)
    first = profile("canonical-profile", priority: 15)
    equivalent = %{first | ipv4: Map.new(Enum.reverse(Map.to_list(first.ipv4)))}

    assert :ok = put(store, first.id, first)
    assert {:ok, first_revision} = revision(store, first.id)
    assert :ok = put(store, equivalent.id, equivalent, expected_revision: first_revision)
    assert {:ok, ^first_revision} = revision(store, first.id)
  end

  test "missing revision precondition only creates an absent profile", %{
    profile_dir: profile_dir
  } do
    {:ok, store} = start_store(profile_dir)
    original = profile("create-only-profile", priority: 10)
    attempted = profile("create-only-profile", priority: 99)

    assert :ok = put(store, original.id, original, expected_revision: :missing)
    assert {:ok, current_revision} = revision(store, original.id)
    assert {:ok, original_contents} = File.read(profile_path(profile_dir, original.id))

    assert {:error, {:conflict, ^current_revision}} =
             put(store, attempted.id, attempted, expected_revision: :missing)

    assert {:ok, ^original} = get(store, original.id)
    assert File.read!(profile_path(profile_dir, original.id)) == original_contents
  end

  test "stale expected revisions reject put and delete without changing disk or cache", %{
    profile_dir: profile_dir
  } do
    {:ok, store} = start_store(profile_dir)
    original = profile("conflict-profile", priority: 10)
    replacement = profile("conflict-profile", priority: 99)

    assert :ok = put(store, original.id, original)
    assert {:ok, current_revision} = revision(store, original.id)
    assert {:ok, original_contents} = File.read(profile_path(profile_dir, original.id))
    stale_revision = String.duplicate("0", 64)

    assert {:error, {:conflict, ^current_revision}} =
             put(store, original.id, replacement, expected_revision: stale_revision)

    assert {:error, {:conflict, ^current_revision}} =
             delete(store, original.id, expected_revision: stale_revision)

    assert {:ok, ^original} = get(store, original.id)
    assert File.read!(profile_path(profile_dir, original.id)) == original_contents
  end

  test "expected revisions are checked against disk before a watcher flush", %{
    profile_dir: profile_dir
  } do
    {:ok, store} = start_store(profile_dir)
    original = profile("disk-conflict", priority: 10)
    external = profile("disk-conflict", priority: 20)
    attempted = profile("disk-conflict", priority: 30)
    path = profile_path(profile_dir, original.id)

    assert :ok = put(store, original.id, original)
    assert {:ok, stale_revision} = revision(store, original.id)

    external_contents = Profile.canonical_toml(external)
    external_revision = sha256(external_contents)
    File.write!(path, external_contents)

    assert {:error, {:conflict, ^external_revision}} =
             put(store, attempted.id, attempted, expected_revision: stale_revision)

    assert File.read!(path) == external_contents
    assert {:ok, ^original} = get(store, original.id)
  end

  test "put rejects unsafe filenames and mismatched profile IDs", %{profile_dir: profile_dir} do
    {:ok, store} = start_store(profile_dir)

    assert {:error, :invalid_id} = put(store, "..", profile(".."))

    assert {:error, :profile_id_mismatch} =
             put(store, "requested-id", profile("different-id"))

    assert File.ls!(profile_dir) == []
  end

  test "a failed write leaves cache and events unchanged and cleans temporary files", %{
    profile_dir: profile_dir
  } do
    {:ok, store} = start_store(profile_dir)
    original = profile("write-failure", priority: 1)
    replacement = profile("write-failure", priority: 2)

    assert :ok = put(store, original.id, original)
    assert {:ok, current_revision} = revision(store, original.id)
    assert {:ok, original_contents} = File.read(profile_path(profile_dir, original.id))
    _operations = drain_file_operations()

    YellowDog.Netman.EventBus.subscribe("netman:profile:changed")
    FileOps.configure(self(), :sync)

    assert {:error, {:write_failed, :injected_failure}} =
             put(store, replacement.id, replacement, expected_revision: current_revision)

    assert {:ok, ^original} = get(store, original.id)
    assert {:ok, ^current_revision} = revision(store, original.id)
    assert File.read!(profile_path(profile_dir, original.id)) == original_contents
    refute_receive {:netman_event, "netman:profile:changed", _}, 100
    assert temporary_files(profile_dir) == []
  end

  test "a failed delete keeps the durable profile, cache, revision, and event state", %{
    profile_dir: profile_dir
  } do
    {:ok, store} = start_store(profile_dir)
    profile = profile("delete-failure")

    assert :ok = put(store, profile.id, profile)
    assert {:ok, current_revision} = revision(store, profile.id)
    _operations = drain_file_operations()

    YellowDog.Netman.EventBus.subscribe("netman:profile:changed")
    FileOps.configure(self(), :rm)

    assert {:error, {:delete_failed, :injected_failure}} =
             delete(store, profile.id, expected_revision: current_revision)

    assert File.regular?(profile_path(profile_dir, profile.id))
    assert {:ok, ^profile} = get(store, profile.id)
    assert {:ok, ^current_revision} = revision(store, profile.id)
    refute_receive {:netman_event, "netman:profile:changed", _}, 100
  end

  test "delete removes the file before cache and delayed self-events cannot resurrect it", %{
    profile_dir: profile_dir
  } do
    {:ok, store} = start_store(profile_dir)
    profile = profile("deleted-profile")
    path = profile_path(profile_dir, profile.id)

    assert :ok = put(store, profile.id, profile)
    assert {:ok, current_revision} = revision(store, profile.id)
    _operations = drain_file_operations()

    send(store, {:file_event, self(), {path, [:modified]}})
    _state = :sys.get_state(store)

    assert :ok = delete(store, profile.id, expected_revision: current_revision)
    refute File.exists?(path)
    assert {:error, :not_found} = get(store, profile.id)
    assert {:error, :not_found} = revision(store, profile.id)

    send(store, :flush_pending_reloads)
    send(store, {:file_event, self(), {path, [:removed]}})
    send(store, :flush_pending_reloads)
    _state = :sys.get_state(store)

    assert {:error, :not_found} = get(store, profile.id)

    GenServer.stop(store)
    {:ok, restarted} = start_store(profile_dir)
    assert {:error, :not_found} = get(restarted, profile.id)
  end

  test "watcher self-events do not republish an unchanged durable profile", %{
    profile_dir: profile_dir
  } do
    {:ok, store} = start_store(profile_dir)
    profile = profile("self-event-profile")
    path = profile_path(profile_dir, profile.id)

    YellowDog.Netman.EventBus.subscribe("netman:profile:changed")

    assert :ok = put(store, profile.id, profile)
    assert_receive {:netman_event, "netman:profile:changed", {:updated, "self-event-profile"}}
    assert {:ok, current_revision} = revision(store, profile.id)

    send(store, {:file_event, self(), {path, [:modified]}})
    send(store, :flush_pending_reloads)
    _state = :sys.get_state(store)

    assert {:ok, ^current_revision} = revision(store, profile.id)

    refute_receive {:netman_event, "netman:profile:changed", {:reloaded, "self-event-profile"}},
                   100
  end

  test "moved_to reloads an atomic external replacement", %{profile_dir: profile_dir} do
    {:ok, store} = start_store(profile_dir)
    original = profile("moved-to-profile", priority: 10)
    replacement = profile("moved-to-profile", priority: 20)
    path = profile_path(profile_dir, original.id)

    assert :ok = put(store, original.id, original)
    File.write!(path, Profile.canonical_toml(replacement))

    send(store, {:file_event, self(), {path, [:moved_from]}})
    send(store, {:file_event, self(), {path, [:moved_to]}})
    send(store, :flush_pending_reloads)
    _state = :sys.get_state(store)

    assert {:ok, ^replacement} = get(store, replacement.id)
  end

  test "delayed legacy-file events cannot overwrite a canonical mutation", %{
    profile_dir: profile_dir
  } do
    original = profile("canonical-event", priority: 10)
    replacement = profile("canonical-event", priority: 20)
    legacy_path = Path.join(profile_dir, "legacy-event.toml")

    File.write!(legacy_path, Profile.canonical_toml(original))
    {:ok, store} = start_store(profile_dir)
    assert :ok = put(store, replacement.id, replacement)

    File.write!(legacy_path, Profile.canonical_toml(original))
    send(store, {:file_event, self(), {legacy_path, [:modified]}})
    send(store, :flush_pending_reloads)
    _state = :sys.get_state(store)

    assert {:ok, ^replacement} = get(store, replacement.id)
  end

  test "deleted and moved_from events remove stale cached profiles", %{profile_dir: profile_dir} do
    {:ok, store} = start_store(profile_dir)
    deleted = profile("linux-deleted-event")
    moved = profile("linux-moved-from-event")
    deleted_path = profile_path(profile_dir, deleted.id)
    moved_path = profile_path(profile_dir, moved.id)

    assert :ok = put(store, deleted.id, deleted)
    assert :ok = put(store, moved.id, moved)
    File.rm!(deleted_path)
    File.rm!(moved_path)

    send(store, {:file_event, self(), {deleted_path, [:deleted]}})
    send(store, {:file_event, self(), {moved_path, [:moved_from]}})
    send(store, :flush_pending_reloads)
    _state = :sys.get_state(store)

    assert {:error, :not_found} = get(store, deleted.id)
    assert {:error, :not_found} = get(store, moved.id)
  end

  test "replacing a managed profile with a symlink removes stale cached state", %{
    profile_dir: profile_dir
  } do
    {:ok, store} = start_store(profile_dir)
    profile = profile("symlink-replacement")
    path = profile_path(profile_dir, profile.id)
    target = path <> ".source"

    assert :ok = put(store, profile.id, profile)
    File.write!(target, Profile.canonical_toml(profile))
    File.rm!(path)
    File.ln_s!(target, path)

    send(store, {:file_event, self(), {path, [:moved_to]}})
    send(store, :flush_pending_reloads)
    _state = :sys.get_state(store)

    assert {:error, :not_found} = get(store, profile.id)
    assert {:error, :not_found} = revision(store, profile.id)
  end

  test "post-rename directory sync failure returns committed put state", %{
    profile_dir: profile_dir
  } do
    {:ok, store} = start_store(profile_dir)
    profile = profile("put-directory-sync")
    path = profile_path(profile_dir, profile.id)

    FileOps.configure(self(), :sync_dir)
    YellowDog.Netman.EventBus.subscribe("netman:profile:changed")

    assert :ok = put(store, profile.id, profile)
    assert File.regular?(path)
    assert {:ok, ^profile} = get(store, profile.id)
    assert {:ok, _revision} = revision(store, profile.id)

    assert_receive {:netman_event, "netman:profile:changed", {:updated, "put-directory-sync"}}
  end

  test "post-unlink directory sync failure returns committed delete state", %{
    profile_dir: profile_dir
  } do
    {:ok, store} = start_store(profile_dir)
    profile = profile("delete-directory-sync")
    path = profile_path(profile_dir, profile.id)

    assert :ok = put(store, profile.id, profile)
    assert {:ok, current_revision} = revision(store, profile.id)
    FileOps.configure(self(), :sync_dir)
    YellowDog.Netman.EventBus.subscribe("netman:profile:changed")

    assert :ok = delete(store, profile.id, expected_revision: current_revision)
    refute File.exists?(path)
    assert {:error, :not_found} = get(store, profile.id)
    assert {:error, :not_found} = revision(store, profile.id)

    assert_receive {:netman_event, "netman:profile:changed", {:deleted, "delete-directory-sync"}}
  end

  test "post-rename directory sync exception cannot prevent cache reconciliation", %{
    profile_dir: profile_dir
  } do
    {:ok, store} = start_store(profile_dir)
    profile = profile("put-directory-sync-exception")
    path = profile_path(profile_dir, profile.id)

    FileOps.configure(self(), {:raise, :sync_dir})
    YellowDog.Netman.EventBus.subscribe("netman:profile:changed")

    assert :ok = put(store, profile.id, profile)
    assert Process.alive?(store)
    assert File.regular?(path)
    assert {:ok, ^profile} = get(store, profile.id)
    assert {:ok, _revision} = revision(store, profile.id)

    assert_receive {:netman_event, "netman:profile:changed",
                    {:updated, "put-directory-sync-exception"}}
  end

  test "post-unlink directory sync exit cannot prevent cache reconciliation", %{
    profile_dir: profile_dir
  } do
    {:ok, store} = start_store(profile_dir)
    profile = profile("delete-directory-sync-exit")
    path = profile_path(profile_dir, profile.id)

    assert :ok = put(store, profile.id, profile)
    assert {:ok, current_revision} = revision(store, profile.id)
    FileOps.configure(self(), {:exit, :sync_dir})
    YellowDog.Netman.EventBus.subscribe("netman:profile:changed")

    assert :ok = delete(store, profile.id, expected_revision: current_revision)
    assert Process.alive?(store)
    refute File.exists?(path)
    assert {:error, :not_found} = get(store, profile.id)
    assert {:error, :not_found} = revision(store, profile.id)

    assert_receive {:netman_event, "netman:profile:changed",
                    {:deleted, "delete-directory-sync-exit"}}
  end

  test "startup creates a missing profile directory before starting its watcher", %{
    profile_dir: profile_dir
  } do
    missing_dir = profile_dir <> "-missing"
    File.rm_rf!(missing_dir)
    on_exit(fn -> File.rm_rf!(missing_dir) end)

    {:ok, store} =
      GenServer.start_link(ProfileStore,
        profile_dir: missing_dir,
        watcher: true,
        name: nil
      )

    state = :sys.get_state(store)

    assert File.dir?(missing_dir)
    assert is_pid(state.watcher_pid)
    assert Process.alive?(state.watcher_pid)
  end

  defp start_store(profile_dir) do
    GenServer.start_link(ProfileStore,
      profile_dir: profile_dir,
      watcher: false,
      file_ops: FileOps
    )
  end

  defp put(store, id, profile, opts \\ []) do
    GenServer.call(store, {:put, id, profile, opts})
  end

  defp get(store, id), do: GenServer.call(store, {:get, id})
  defp import_file(store, path), do: GenServer.call(store, {:import_file, path})
  defp revision(store, id), do: GenServer.call(store, {:revision, id})
  defp delete(store, id, opts), do: GenServer.call(store, {:delete, id, opts})

  defp profile(id, opts \\ []) do
    %Profile{
      id: id,
      type: :ethernet,
      interface: Keyword.get(opts, :interface),
      autoconnect: true,
      autoconnect_priority: Keyword.get(opts, :priority, 0),
      zone: "default",
      ethernet: %{mtu: 1500},
      ipv4: %{method: :auto, address: nil, gateway: nil, dns: [], dns_search: []},
      ipv6: %{method: :disabled, address: nil, gateway: nil, dns: [], dns_search: []}
    }
  end

  defp profile_path(profile_dir, id), do: Path.join(profile_dir, "#{id}.toml")

  defp sha256(contents) do
    :crypto.hash(:sha256, contents)
    |> Base.encode16(case: :lower)
  end

  defp temporary_files(profile_dir) do
    Path.wildcard(Path.join(profile_dir, ".*.tmp"))
  end

  defp drain_file_operations(operations \\ []) do
    receive do
      {:profile_store_file_op, operation, details} ->
        drain_file_operations([{operation, details} | operations])
    after
      0 -> Enum.reverse(operations)
    end
  end

  defp assert_ordered(operations, expected) do
    positions =
      Enum.map(expected, fn expected_operation ->
        Enum.find_index(operations, fn {operation, _details} ->
          operation == expected_operation
        end)
      end)

    assert Enum.all?(positions, &is_integer/1)
    assert positions == Enum.sort(positions)
  end
end
