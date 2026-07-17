defmodule YellowDog.Netboot.Asset.StoreTest do
  use ExUnit.Case, async: false

  alias YellowDog.Netboot.Asset.Ledger
  alias YellowDog.Netboot.Asset.ManagedAsset
  alias YellowDog.Netboot.Asset.Store
  alias YellowDog.Netboot.Asset.StoreTestIndexOps
  alias YellowDog.Netboot.TFTP.FileIndex

  setup do
    base = Path.join(System.tmp_dir!(), "netboot_asset_store_#{unique()}")
    root = Path.join(base, "tftp")
    ledger_path = Path.join(base, "managed/managed_assets.json")
    File.mkdir_p!(root)

    FileIndex.init()
    :ok = FileIndex.replace([])

    on_exit(fn -> File.rm_rf!(base) end)

    %{base: base, root: root, ledger_path: ledger_path}
  end

  test "snapshot is deterministic, active-only, and never claims untracked files", context do
    zeta = put_asset(context, "zeta", "images/zeta.img", "zeta")
    alpha = put_asset(context, "alpha", "images/alpha.img", "alpha")
    File.write!(Path.join(context.root, "operator.img"), "operator")

    store = start_store(context)

    assert {:ok, resources} = Store.control_snapshot(store)

    assert resources == [
             ManagedAsset.to_resource(alpha),
             ManagedAsset.to_resource(zeta)
           ]

    refute Enum.any?(resources, &(&1["filename"] == "operator.img"))

    assert store
           |> Store.list_files()
           |> Enum.map(& &1.path)
           |> Enum.sort() == ["images/alpha.img", "images/zeta.img", "operator.img"]
  end

  test "restart reloads the active ledger without changing it", context do
    asset = put_asset(context, "installer", "images/installer.img", "managed")
    ledger_before = File.read!(context.ledger_path)

    store = start_store(context)
    assert {:ok, [resource]} = Store.control_snapshot(store)
    assert resource == ManagedAsset.to_resource(asset)

    stop_store(store)
    restarted = start_store(context)

    assert {:ok, [^resource]} = Store.control_snapshot(restarted)
    assert File.read!(context.ledger_path) == ledger_before
  end

  test "startup rejects a duplicate ledger", context do
    duplicate = [
      asset_document("one", "installer.img", "one"),
      asset_document("two", "installer.img", "two")
    ]

    write_ledger_document(context, duplicate)

    assert {:error, {:ledger_load_failed, :duplicate_filename}} =
             start_store_result(context)
  end

  test "startup rejects an obsolete tombstoned entry without recovering it", context do
    tombstoned =
      asset_document("installer", "installer.img", "managed")
      |> Map.put("lifecycle", "tombstoned")
      |> Map.put("tombstone_filename", legacy_tombstone_filename("installer"))

    write_ledger_document(context, [tombstoned])
    ledger_before = File.read!(context.ledger_path)

    assert {:error, {:ledger_load_failed, :invalid_lifecycle}} =
             start_store_result(context)

    assert File.read!(context.ledger_path) == ledger_before
  end

  test "startup rejects obsolete tombstone metadata on an active entry", context do
    active =
      asset_document("installer", "installer.img", "managed")
      |> Map.put("tombstone_filename", legacy_tombstone_filename("installer"))

    write_ledger_document(context, [active])
    ledger_before = File.read!(context.ledger_path)

    assert {:error, {:ledger_load_failed, :invalid_asset}} =
             start_store_result(context)

    assert File.read!(context.ledger_path) == ledger_before
  end

  test "the configured ledger path remains outside the TFTP root", context do
    store = start_store(context)

    assert Store.root_dir(store) == context.root
    assert Store.managed_assets_path(store) == context.ledger_path

    refute String.starts_with?(
             Path.expand(Store.managed_assets_path(store)),
             Path.expand(context.root) <> "/"
           )
  end

  test "startup rejects any ledger path inside the TFTP root" do
    assert {:error, {:asset_store_start_failed, :ledger_inside_tftp_root}} =
             GenServer.start(
               Store,
               [
                 config: %{
                   tftp_root: "/",
                   managed_assets_path: Path.join(System.tmp_dir!(), "managed_assets.json")
                 }
               ],
               []
             )
  end

  test "local upload preserves the legacy copy and overwrite API", context do
    source = Path.join(context.base, "source.img")
    File.write!(source, "source")
    store = start_store(context)

    assert function_exported?(Store, :upload_file, 2)
    assert :ok = Store.upload_file("nested/installer.img", source, store)
    assert File.read!(Path.join(context.root, "nested/installer.img")) == "source"

    File.write!(source, "replacement")
    assert :ok = Store.upload_file("nested/installer.img", source, store)
    assert File.read!(Path.join(context.root, "nested/installer.img")) == "replacement"
    assert {:ok, []} = Store.control_snapshot(store)
  end

  test "local upload rejects traversal and reports a missing source", context do
    store = start_store(context)

    assert {:error, :path_traversal} =
             Store.upload_file("../installer.img", "/tmp/source", store)

    assert {:error, :enoent} =
             Store.upload_file("installer.img", "/nonexistent/source", store)
  end

  test "local delete preserves the legacy path-based API", context do
    operator_path = Path.join(context.root, "operator.img")
    File.write!(operator_path, "operator")
    store = start_store(context)

    assert function_exported?(Store, :delete_file, 1)
    assert :ok = Store.delete_file("operator.img", store)
    refute File.exists?(operator_path)
    assert {:error, :enoent} = Store.delete_file("operator.img", store)
    assert {:error, :path_traversal} = Store.delete_file("../operator.img", store)
  end

  test "control delete of an existing asset is unsupported with zero mutation", context do
    asset = put_asset(context, "installer", "images/installer.img", "managed")
    store = start_store(context)

    before = owner_state(context, store, asset.filename)

    assert {:error, :unsupported} = Store.control_delete_asset(asset.asset_id, store)
    assert owner_state(context, store, asset.filename) == before
    assert {:ok, [resource]} = Store.control_snapshot(store)
    assert resource == ManagedAsset.to_resource(asset)
  end

  test "control delete of a missing valid ID is unsupported with zero mutation", context do
    operator_path = Path.join(context.root, "operator.img")
    File.write!(operator_path, "operator")
    store = start_store(context)

    before = owner_state(context, store, "operator.img")

    assert {:error, :unsupported} = Store.control_delete_asset("missing-asset", store)
    assert owner_state(context, store, "operator.img") == before
    assert {:ok, []} = Store.control_snapshot(store)
  end

  test "control delete rejects malformed asset IDs without mutation", context do
    store = start_store(context)
    before = owner_state(context, store, nil)

    for asset_id <- [nil, "", ".", "..", "bad/id", "bad\\id", "bad\nid"] do
      assert {:error, :invalid} = Store.control_delete_asset(asset_id, store)
    end

    assert owner_state(context, store, nil) == before
  end

  test "rescan all counts every safe regular file and leaves the ledger byte-identical",
       context do
    _asset = put_asset(context, "installer", "installer.img", "managed")
    File.mkdir_p!(Path.join(context.root, "nested"))
    File.write!(Path.join(context.root, "operator.img"), "operator")
    File.write!(Path.join(context.root, "nested/other.img"), "other")
    ledger_before = File.read!(context.ledger_path)
    store = start_store(context)

    assert {:ok, 3} = Store.control_rescan("all", store)
    assert FileIndex.count() == 3
    assert File.read!(context.ledger_path) == ledger_before
    assert {:ok, [_resource]} = Store.control_snapshot(store)
  end

  test "rescan missing counts files absent from the pre-scan index and rebuilds it", context do
    File.write!(Path.join(context.root, "known.img"), "known")
    store = start_store(context)
    File.write!(Path.join(context.root, "new.img"), "new")

    assert {:ok, 1} = Store.control_rescan("missing", store)
    assert FileIndex.count() == 2

    assert {:ok, 0} = Store.control_rescan("missing", store)
    assert FileIndex.count() == 2
    assert {:ok, []} = Store.control_snapshot(store)
  end

  test "rescan skips symlinks and preserves the active index when discovery fails", context do
    outside = Path.join(context.base, "outside.img")
    File.write!(outside, "outside")
    File.ln_s!(outside, Path.join(context.root, "linked.img"))
    File.write!(Path.join(context.root, "regular.img"), "regular")
    {:ok, index_ops} = StoreTestIndexOps.start_link(%{})
    store = start_store(context, index_ops: {StoreTestIndexOps, index_ops})
    previous_index = FileIndex.snapshot()
    StoreTestIndexOps.fail_next(index_ops, :build_snapshot)

    assert {:error, :apply_failed} = Store.control_rescan("all", store)
    assert FileIndex.snapshot() == previous_index
    assert {:ok, []} = Store.control_snapshot(store)
  end

  test "a Store-only restart rebuilds the complete live FileIndex", context do
    asset = put_asset(context, "installer", "installer.img", "managed")
    operator_path = Path.join(context.root, "operator.img")
    File.write!(operator_path, "operator")

    :ets.delete(FileIndex)
    store = start_store(context)

    assert {:ok, _, _} = FileIndex.lookup(asset.filename, context.root)
    assert {:ok, ^operator_path, _} = FileIndex.lookup("operator.img", context.root)
    assert :ets.info(FileIndex, :owner) == store

    stop_store(store)
    assert :ets.whereis(FileIndex) == :undefined

    restarted = start_store(context)
    assert {:ok, _, _} = FileIndex.lookup(asset.filename, context.root)
    assert {:ok, ^operator_path, _} = FileIndex.lookup("operator.img", context.root)
    assert :ets.info(FileIndex, :owner) == restarted
  end

  defp owner_state(context, store, payload_filename) do
    %{
      process: :sys.get_state(store),
      ledger: File.read(context.ledger_path),
      index: FileIndex.snapshot(),
      payload: read_payload(context.root, payload_filename)
    }
  end

  defp read_payload(_root, nil), do: :not_applicable
  defp read_payload(root, filename), do: File.read(Path.join(root, filename))

  defp put_asset(context, asset_id, filename, contents) do
    path = Path.join(context.root, filename)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)

    {:ok, asset} =
      asset_document(asset_id, filename, contents)
      |> ManagedAsset.from_document()

    {:ok, ledger} = Ledger.load(context.ledger_path)
    {:ok, ledger} = Ledger.put(ledger, asset)
    :ok = Ledger.write(context.ledger_path, ledger)
    asset
  end

  defp asset_document(asset_id, filename, contents) do
    %{
      "asset_id" => asset_id,
      "filename" => filename,
      "size" => byte_size(contents),
      "blob_digest" => sha256(contents),
      "ownership" => "managed",
      "lifecycle" => "active"
    }
  end

  defp write_ledger_document(context, assets) do
    File.mkdir_p!(Path.dirname(context.ledger_path))
    File.write!(context.ledger_path, Jason.encode!(%{"version" => 1, "assets" => assets}))
  end

  defp start_store(context, opts \\ []) do
    assert {:ok, pid} = start_store_result(context, opts)
    pid
  end

  defp start_store_result(context, opts \\ []) do
    result =
      GenServer.start(
        Store,
        Keyword.merge(
          [
            config: %{
              tftp_root: context.root,
              managed_assets_path: context.ledger_path
            }
          ],
          opts
        ),
        []
      )

    case result do
      {:ok, pid} -> on_exit(fn -> stop_store(pid) end)
      _other -> :ok
    end

    result
  end

  defp stop_store(store) do
    if Process.alive?(store), do: GenServer.stop(store)
  end

  defp sha256(contents) do
    :crypto.hash(:sha256, contents)
    |> Base.encode16(case: :lower)
  end

  defp legacy_tombstone_filename(asset_id) do
    digest = sha256(asset_id)
    ".yellowdog-delete-#{digest}.tombstone"
  end

  defp unique, do: System.unique_integer([:positive, :monotonic])
end
