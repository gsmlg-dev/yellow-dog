defmodule YellowDog.Netman.ProfileStoreLifecycleTest do
  use ExUnit.Case, async: false

  alias YellowDog.Netman.ProfileStore
  alias YellowDog.Netman.Types.Profile

  defmodule SuccessfulReconciler do
    def activate(_profile_id), do: :ok
  end

  defmodule FailingReconciler do
    def activate(_profile_id), do: {:error, :apply_failed}
  end

  setup do
    profile_dir =
      Path.join(
        System.tmp_dir!(),
        "netman-profile-lifecycle-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(profile_dir)
    {:ok, store} = start_store(profile_dir)

    on_exit(fn ->
      if Process.alive?(store), do: GenServer.stop(store)
      File.rm_rf!(profile_dir)
    end)

    {:ok, profile_dir: profile_dir, store: store}
  end

  test "stores immutable profile revisions with durable history", %{
    profile_dir: profile_dir,
    store: store
  } do
    original = profile("history-profile", priority: 10)
    replacement = profile("history-profile", priority: 20)

    assert :ok = put(store, original)
    assert {:ok, original_revision} = revision(store, original.id)
    assert :ok = put(store, replacement, expected_revision: original_revision)
    assert {:ok, replacement_revision} = revision(store, replacement.id)

    assert {:ok, history} = history(store, original.id)
    assert Enum.map(history, & &1.revision) == [replacement_revision, original_revision]

    assert Enum.find(history, &(&1.revision == original_revision)).profile == original
    assert Enum.find(history, &(&1.revision == replacement_revision)).profile == replacement
    assert Enum.all?(history, &match?(%DateTime{}, &1.stored_at))
    assert Enum.all?(history, &is_nil(&1.activated_at))

    GenServer.stop(store)
    {:ok, restarted} = start_store(profile_dir)

    assert {:ok, restarted_history} = history(restarted, original.id)

    assert Enum.map(restarted_history, &{&1.revision, &1.profile}) ==
             Enum.map(history, &{&1.revision, &1.profile})

    GenServer.stop(restarted)
  end

  test "desired and active revisions advance independently and survive restart", %{
    profile_dir: profile_dir,
    store: store
  } do
    original = profile("active-profile", priority: 10)
    replacement = profile("active-profile", priority: 20)

    assert :ok = put(store, original)
    assert {:ok, original_revision} = revision(store, original.id)

    assert {:ok, %{desired_revision: ^original_revision, active_revision: nil}} =
             state(store, original.id)

    assert :ok = mark_active(store, original.id, original_revision)

    assert {:ok, %{desired_revision: ^original_revision, active_revision: ^original_revision}} =
             state(store, original.id)

    assert :ok = put(store, replacement, expected_revision: original_revision)
    assert {:ok, replacement_revision} = revision(store, original.id)

    assert {:ok, %{desired_revision: ^replacement_revision, active_revision: ^original_revision}} =
             state(store, original.id)

    assert {:error, {:conflict, ^replacement_revision}} =
             mark_active(store, original.id, original_revision)

    GenServer.stop(store)
    {:ok, restarted} = start_store(profile_dir)

    assert {:ok, %{desired_revision: ^replacement_revision, active_revision: ^original_revision}} =
             state(restarted, original.id)

    assert {:ok, restarted_history} = history(restarted, original.id)

    assert %DateTime{} =
             Enum.find(restarted_history, &(&1.revision == original_revision)).activated_at

    GenServer.stop(restarted)
  end

  test "refuses to overwrite a corrupted immutable history snapshot", %{
    profile_dir: profile_dir,
    store: store
  } do
    original = profile("immutable-profile", priority: 10)
    tampered = profile("immutable-profile", priority: 99)

    assert :ok = put(store, original)
    assert {:ok, revision} = revision(store, original.id)

    snapshot = Path.join([profile_dir, ".history", original.id, "#{revision}.toml"])
    File.write!(snapshot, Profile.canonical_toml(tampered))
    GenServer.stop(store)

    assert {:error, {:profile_history_unavailable, {:history_snapshot_conflict, ^snapshot}}} =
             GenServer.start(ProfileStore,
               profile_dir: profile_dir,
               watcher: false,
               name: nil
             )
  end

  test "rollback restores an immutable snapshot as desired without claiming activation", %{
    store: store
  } do
    original = profile("rollback-profile", priority: 10)
    replacement = profile("rollback-profile", priority: 20)

    assert :ok = put(store, original)
    assert {:ok, original_revision} = revision(store, original.id)
    assert :ok = mark_active(store, original.id, original_revision)
    assert :ok = put(store, replacement, expected_revision: original_revision)
    assert {:ok, replacement_revision} = revision(store, original.id)

    assert {:ok, ^original_revision} =
             rollback(store, original.id, original_revision,
               expected_revision: replacement_revision
             )

    assert {:ok, ^original} = get(store, original.id)

    assert {:ok, %{desired_revision: ^original_revision, active_revision: ^original_revision}} =
             state(store, original.id)

    assert {:error, :revision_not_found} =
             rollback(store, original.id, String.duplicate("f", 64),
               expected_revision: original_revision
             )
  end

  test "authoritative replacement deletes every omitted pre-existing local profile", %{
    profile_dir: profile_dir,
    store: store
  } do
    omitted = profile("local-before-management", priority: 1)
    retained = profile("retained-profile", priority: 2)
    replacement = profile("retained-profile", priority: 3)
    added = profile("management-added", priority: 4)

    assert :ok = put(store, omitted)
    assert :ok = put(store, retained)
    assert {:ok, namespace_revision} = namespace_revision(store)

    assert {:ok, applied_revision} =
             replace(store, [replacement, added], expected_revision: namespace_revision)

    assert applied_revision != namespace_revision
    assert {:error, :not_found} = get(store, omitted.id)
    assert {:ok, ^replacement} = get(store, retained.id)
    assert {:ok, ^added} = get(store, added.id)
    assert Enum.sort(Enum.map(list(store), & &1.id)) == [added.id, retained.id]

    assert {:ok, omitted_history} = history(store, omitted.id)
    assert Enum.any?(omitted_history, &(&1.profile == omitted))

    GenServer.stop(store)
    {:ok, restarted} = start_store(profile_dir)

    assert {:error, :not_found} = get(restarted, omitted.id)
    assert {:ok, ^replacement} = get(restarted, retained.id)
    assert {:ok, ^added} = get(restarted, added.id)
    assert {:ok, restarted_omitted_history} = history(restarted, omitted.id)
    assert Enum.any?(restarted_omitted_history, &(&1.profile == omitted))
    GenServer.stop(restarted)
  end

  test "facade records activation only after the reconciler succeeds" do
    profile = profile("facade-active-#{System.unique_integer([:positive])}")
    on_exit(fn -> YellowDog.Netman.delete_profile(profile.id) end)

    assert :ok = YellowDog.Netman.put_profile(profile.id, profile)
    assert {:ok, desired_revision} = YellowDog.Netman.profile_revision(profile.id)

    assert {:error, :apply_failed} = YellowDog.Netman.activate(profile.id, FailingReconciler)

    assert {:ok, %{active_revision: nil}} = YellowDog.Netman.profile_state(profile.id)

    assert :ok = YellowDog.Netman.activate(profile.id, SuccessfulReconciler)

    assert {:ok, %{active_revision: ^desired_revision}} =
             YellowDog.Netman.profile_state(profile.id)
  end

  defp start_store(profile_dir) do
    GenServer.start_link(ProfileStore, profile_dir: profile_dir, watcher: false, name: nil)
  end

  defp put(store, profile, opts \\ []),
    do: GenServer.call(store, {:put, profile.id, profile, opts})

  defp get(store, id), do: GenServer.call(store, {:get, id})
  defp list(store), do: GenServer.call(store, :list)
  defp revision(store, id), do: GenServer.call(store, {:revision, id})
  defp state(store, id), do: GenServer.call(store, {:state, id})
  defp history(store, id), do: GenServer.call(store, {:history, id})
  defp mark_active(store, id, revision), do: GenServer.call(store, {:mark_active, id, revision})

  defp rollback(store, id, target_revision, opts),
    do: GenServer.call(store, {:rollback, id, target_revision, opts})

  defp namespace_revision(store), do: GenServer.call(store, :namespace_revision)

  defp replace(store, profiles, opts),
    do: GenServer.call(store, {:replace, profiles, opts}, 30_000)

  defp profile(id, opts \\ []) do
    %Profile{
      id: id,
      type: :ethernet,
      interface: "eth0",
      autoconnect: true,
      autoconnect_priority: Keyword.get(opts, :priority, 0),
      zone: "default",
      ethernet: %{mtu: 1_500},
      ipv4: %{method: :auto, address: nil, gateway: nil, dns: [], dns_search: []},
      ipv6: %{method: :disabled, address: nil, gateway: nil, dns: [], dns_search: []}
    }
  end
end
