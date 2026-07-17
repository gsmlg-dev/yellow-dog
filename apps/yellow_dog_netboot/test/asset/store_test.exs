defmodule YellowDog.Netboot.Asset.StoreTest do
  use ExUnit.Case, async: false

  alias YellowDog.Netboot.Asset.Ledger
  alias YellowDog.Netboot.Asset.ManagedAsset
  alias YellowDog.Netboot.Asset.Store
  alias YellowDog.Netboot.Asset.StoreTestFileOps
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

  test "restart loads only active ledger-owned assets and never claims untracked files",
       context do
    File.write!(Path.join(context.root, "operator.img"), "operator data")
    asset = put_asset(context, "installer", "images/installer.img", "managed data")

    store = start_store(context)

    assert {:ok, [resource]} = Store.control_snapshot(store)
    assert resource == ManagedAsset.to_resource(asset)
    refute Enum.any?(elem(Store.control_snapshot(store), 1), &(&1["filename"] == "operator.img"))

    stop_store(store)
    restarted = start_store(context)
    assert {:ok, [^resource]} = Store.control_snapshot(restarted)
  end

  test "startup rejects a malformed or duplicate ledger", context do
    duplicate = [
      asset_document("one", "installer.img", "one"),
      asset_document("two", "installer.img", "two")
    ]

    File.mkdir_p!(Path.dirname(context.ledger_path))

    File.write!(
      context.ledger_path,
      Jason.encode!(%{"version" => 1, "assets" => duplicate})
    )

    assert {:error, {:ledger_load_failed, :duplicate_filename}} = start_store_result(context)
  end

  test "the configurable ledger path remains outside the TFTP root", context do
    store = start_store(context)

    assert Store.root_dir(store) == context.root
    assert Store.managed_assets_path(store) == context.ledger_path

    refute String.starts_with?(
             Path.expand(Store.managed_assets_path(store)),
             Path.expand(context.root) <> "/"
           )
  end

  test "startup rejects any ledger path inside a root TFTP tree" do
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

  test "upload remains unsupported and does not create a payload", context do
    source = Path.join(context.base, "source.img")
    File.write!(source, "source")
    store = start_store(context)

    assert {:error, :unsupported} = Store.upload_file("installer.img", source, store)
    refute File.exists?(Path.join(context.root, "installer.img"))
    assert {:ok, []} = Store.control_snapshot(store)
  end

  test "delete rejects untracked files and preserves their bytes", context do
    operator_path = Path.join(context.root, "operator.img")
    File.write!(operator_path, "operator")
    store = start_store(context)

    assert {:error, :not_found} = Store.control_delete_asset("operator", store)
    assert File.read!(operator_path) == "operator"
  end

  test "legacy path deletion is unsupported and preserves an untracked file", context do
    operator_path = Path.join(context.root, "operator.img")
    File.write!(operator_path, "operator")
    store = start_store(context)

    assert {:error, :unsupported} = Store.delete_file("operator.img", store)
    assert File.read!(operator_path) == "operator"
  end

  test "delete removes an active managed payload, ledger entry, and index entry", context do
    asset = put_asset(context, "installer", "images/installer.img", "managed data")
    assert {:ok, 1} = FileIndex.scan(context.root)
    store = start_store(context)

    assert {:ok, resource} = Store.control_delete_asset("installer", store)
    assert resource == ManagedAsset.to_resource(asset)
    refute File.exists?(Path.join(context.root, asset.filename))
    assert {:ok, []} = Store.control_snapshot(store)
    assert {:error, :not_found} = FileIndex.lookup(asset.filename, context.root)
    assert {:ok, %Ledger{assets: %{}}} = Ledger.load(context.ledger_path)
    assert [] == Path.wildcard(Path.join([context.root, "images", ".yellowdog-delete-*"]))
  end

  test "delete never removes bytes that no longer match the ledger", context do
    asset = put_asset(context, "installer", "installer.img", "managed data")
    payload_path = Path.join(context.root, asset.filename)
    File.write!(payload_path, "operator replacement")
    assert {:ok, 1} = FileIndex.scan(context.root)
    previous_index = FileIndex.snapshot()
    previous_ledger = File.read!(context.ledger_path)
    store = start_store(context)

    assert {:error, :conflict} = Store.control_delete_asset("installer", store)
    assert File.read!(payload_path) == "operator replacement"
    assert File.read!(context.ledger_path) == previous_ledger
    assert FileIndex.snapshot() == previous_index
  end

  test "delete does not overwrite an untracked file at the tombstone path", context do
    asset = put_asset(context, "installer", "installer.img", "managed")
    tombstone_path = tombstone_path(context, asset)
    store = start_store(context)
    File.write!(tombstone_path, "operator")

    assert {:error, :conflict} = Store.control_delete_asset("installer", store)
    assert File.read!(Path.join(context.root, asset.filename)) == "managed"
    assert File.read!(tombstone_path) == "operator"
    assert {:ok, [_resource]} = Store.control_snapshot(store)
  end

  test "rescan all counts every safe regular file and leaves the ledger unchanged", context do
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

  test "rescan missing counts files absent from the pre-scan index then rebuilds it", context do
    File.write!(Path.join(context.root, "known.img"), "known")
    assert {:ok, 1} = FileIndex.scan(context.root)
    File.write!(Path.join(context.root, "new.img"), "new")
    store = start_store(context)

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
    assert {:ok, 1} = FileIndex.scan(context.root)
    previous_index = FileIndex.snapshot()
    {:ok, index_ops} = StoreTestIndexOps.start_link(%{build_snapshot: [1]})
    store = start_store(context, index_ops: {StoreTestIndexOps, index_ops})

    assert {:error, :apply_failed} = Store.control_rescan("all", store)
    assert FileIndex.snapshot() == previous_index
    assert {:ok, []} = Store.control_snapshot(store)
  end

  test "restart restores a deterministic tombstone when the active ledger was not committed",
       context do
    asset = put_asset(context, "installer", "images/installer.img", "managed")
    payload_path = Path.join(context.root, asset.filename)
    tombstone_filename = ManagedAsset.tombstone_filename(asset)
    tombstone_path = Path.join(context.root, tombstone_filename)
    File.rename!(payload_path, tombstone_path)

    store = start_store(context)

    assert File.read!(payload_path) == "managed"
    refute File.exists?(tombstone_path)
    assert {:ok, [_resource]} = Store.control_snapshot(store)
  end

  test "restart completes a durably tombstoned delete", context do
    asset = put_asset(context, "installer", "images/installer.img", "managed")
    tombstone_filename = ManagedAsset.tombstone_filename(asset)
    {:ok, tombstoned} = ManagedAsset.tombstone(asset, tombstone_filename)
    {:ok, ledger} = Ledger.load(context.ledger_path)
    {:ok, ledger} = Ledger.replace(ledger, tombstoned)
    :ok = Ledger.write(context.ledger_path, ledger)

    payload_path = Path.join(context.root, asset.filename)
    tombstone_path = Path.join(context.root, tombstone_filename)
    File.rename!(payload_path, tombstone_path)
    assert {:ok, 1} = FileIndex.scan(context.root)

    store = start_store(context)

    refute File.exists?(payload_path)
    refute File.exists?(tombstone_path)
    assert {:ok, []} = Store.control_snapshot(store)
    assert FileIndex.count() == 0
    assert {:ok, %Ledger{assets: %{}}} = Ledger.load(context.ledger_path)
  end

  test "restart completes a tombstoned ledger whose payload rename was compensated", context do
    asset = put_asset(context, "installer", "installer.img", "managed")
    tombstone_filename = ManagedAsset.tombstone_filename(asset)
    {:ok, tombstoned} = ManagedAsset.tombstone(asset, tombstone_filename)
    {:ok, ledger} = Ledger.load(context.ledger_path)
    {:ok, ledger} = Ledger.replace(ledger, tombstoned)
    :ok = Ledger.write(context.ledger_path, ledger)

    store = start_store(context)

    refute File.exists?(Path.join(context.root, asset.filename))
    refute File.exists?(Path.join(context.root, tombstone_filename))
    assert {:ok, []} = Store.control_snapshot(store)
    assert {:ok, %Ledger{assets: %{}}} = Ledger.load(context.ledger_path)
  end

  test "payload rename failure preserves the active file, ledger, and index", context do
    asset = put_asset(context, "installer", "installer.img", "managed")
    assert {:ok, 1} = FileIndex.scan(context.root)
    index_before = FileIndex.snapshot()
    ledger_before = File.read!(context.ledger_path)
    tombstone_path = tombstone_path(context, asset)
    {:ok, file_ops} = StoreTestFileOps.start_link(%{{:rename, tombstone_path} => [1]})
    store = start_store(context, file_ops: {StoreTestFileOps, file_ops})

    assert {:error, :apply_failed} = Store.control_delete_asset("installer", store)
    assert File.read!(Path.join(context.root, asset.filename)) == "managed"
    refute File.exists?(tombstone_path)
    assert File.read!(context.ledger_path) == ledger_before
    assert FileIndex.snapshot() == index_before
  end

  test "candidate ledger failure restores the file and prior index", context do
    asset = put_asset(context, "installer", "installer.img", "managed")
    assert {:ok, 1} = FileIndex.scan(context.root)
    index_before = FileIndex.snapshot()
    ledger_before = File.read!(context.ledger_path)
    {:ok, file_ops} = StoreTestFileOps.start_link(%{{:rename, context.ledger_path} => [1]})
    store = start_store(context, file_ops: {StoreTestFileOps, file_ops})

    assert {:error, :apply_failed} = Store.control_delete_asset("installer", store)
    assert File.read!(Path.join(context.root, asset.filename)) == "managed"
    refute File.exists?(tombstone_path(context, asset))
    assert File.read!(context.ledger_path) == ledger_before
    assert FileIndex.snapshot() == index_before
  end

  test "index activation failure restores the file, prior ledger, and prior index", context do
    asset = put_asset(context, "installer", "installer.img", "managed")
    assert {:ok, 1} = FileIndex.scan(context.root)
    index_before = FileIndex.snapshot()
    ledger_before = File.read!(context.ledger_path)
    {:ok, index_ops} = StoreTestIndexOps.start_link(%{replace: [1]})
    store = start_store(context, index_ops: {StoreTestIndexOps, index_ops})

    assert {:error, :apply_failed} = Store.control_delete_asset("installer", store)
    assert File.read!(Path.join(context.root, asset.filename)) == "managed"
    refute File.exists?(tombstone_path(context, asset))
    assert File.read!(context.ledger_path) == ledger_before
    assert FileIndex.snapshot() == index_before
  end

  test "tombstone removal failure leaves a recoverable ledger and restart completes delete",
       context do
    asset = put_asset(context, "installer", "installer.img", "managed")
    tombstone_path = tombstone_path(context, asset)
    {:ok, file_ops} = StoreTestFileOps.start_link(%{{:rm, tombstone_path} => [1]})
    store = start_store(context, file_ops: {StoreTestFileOps, file_ops})

    assert {:error, :apply_failed} = Store.control_delete_asset("installer", store)
    assert File.exists?(tombstone_path)
    assert {:ok, ledger} = Ledger.load(context.ledger_path)
    assert {:ok, %{lifecycle: :tombstoned}} = Ledger.fetch(ledger, "installer")

    stop_store(store)
    restarted = start_store(context)
    assert {:ok, []} = Store.control_snapshot(restarted)
    refute File.exists?(tombstone_path)
    assert {:ok, %Ledger{assets: %{}}} = Ledger.load(context.ledger_path)
  end

  test "final ledger failure is recoverable by retry after the tombstone is removed", context do
    asset = put_asset(context, "installer", "installer.img", "managed")
    {:ok, file_ops} = StoreTestFileOps.start_link(%{{:rename, context.ledger_path} => [2]})
    store = start_store(context, file_ops: {StoreTestFileOps, file_ops})

    assert {:error, :apply_failed} = Store.control_delete_asset("installer", store)
    refute File.exists?(Path.join(context.root, asset.filename))
    refute File.exists?(tombstone_path(context, asset))
    assert {:ok, ledger} = Ledger.load(context.ledger_path)
    assert {:ok, %{lifecycle: :tombstoned}} = Ledger.fetch(ledger, "installer")

    assert {:ok, _resource} = Store.control_delete_asset("installer", store)
    assert {:ok, %Ledger{assets: %{}}} = Ledger.load(context.ledger_path)
  end

  test "failed compensation never overwrites a path and restart can recover the tombstone",
       context do
    asset = put_asset(context, "installer", "installer.img", "managed")
    payload_path = Path.join(context.root, asset.filename)

    failures = %{
      {:rename, context.ledger_path} => [1],
      {:rename, payload_path} => [1]
    }

    {:ok, file_ops} = StoreTestFileOps.start_link(failures)
    store = start_store(context, file_ops: {StoreTestFileOps, file_ops})

    assert {:error, :rollback_failed} = Store.control_delete_asset("installer", store)
    refute File.exists?(payload_path)
    assert File.exists?(tombstone_path(context, asset))

    stop_store(store)
    restarted = start_store(context)
    assert File.read!(payload_path) == "managed"
    refute File.exists?(tombstone_path(context, asset))
    assert {:ok, [_resource]} = Store.control_snapshot(restarted)
  end

  defp put_asset(context, asset_id, filename, contents) do
    path = Path.join(context.root, filename)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)

    {:ok, asset} =
      asset_document(asset_id, filename, contents)
      |> ManagedAsset.from_document()

    ledger =
      case Ledger.load(context.ledger_path) do
        {:ok, ledger} -> ledger
        {:error, :enoent} -> Ledger.empty()
      end

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

  defp start_store(context, opts \\ []) do
    assert {:ok, pid} = start_store_result(context, opts)
    on_exit(fn -> stop_store(pid) end)
    pid
  end

  defp start_store_result(context, opts \\ []) do
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
  end

  defp stop_store(store) do
    if Process.alive?(store), do: GenServer.stop(store)
  end

  defp sha256(contents) do
    :crypto.hash(:sha256, contents)
    |> Base.encode16(case: :lower)
  end

  defp tombstone_path(context, asset) do
    Path.join(context.root, ManagedAsset.tombstone_filename(asset))
  end

  defp unique, do: System.unique_integer([:positive, :monotonic])
end
