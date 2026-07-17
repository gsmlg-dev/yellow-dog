defmodule YellowDog.Netboot.Asset.FileOpsTest do
  use ExUnit.Case, async: true

  alias YellowDog.Netboot.Asset.FileOps
  alias YellowDog.Netboot.Asset.ManagedAsset

  setup do
    root = Path.join(System.tmp_dir!(), "netboot_asset_file_ops_#{unique()}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "a target created after verification is never overwritten", %{root: root} do
    source = Path.join(root, "installer.img")
    target = Path.join(root, ".installer.tombstone")
    File.write!(source, "managed")

    before_transition = fn ^source, ^target ->
      File.write!(target, "operator")
      :ok
    end

    assert {:error, :target_exists} =
             FileOps.move_verified(
               source,
               target,
               managed_asset("installer", "installer.img", "managed"),
               before_transition: before_transition
             )

    assert File.read!(source) == "managed"
    assert File.read!(target) == "operator"
  end

  test "a source replaced after verification is detected after the atomic move", %{root: root} do
    source = Path.join(root, "installer.img")
    target = Path.join(root, ".installer.tombstone")
    preserved = Path.join(root, "preserved-managed.img")
    File.write!(source, "managed")

    before_transition = fn ^source, ^target ->
      File.rename!(source, preserved)
      File.write!(source, "operator")
      :ok
    end

    assert {:error, :source_changed} =
             FileOps.move_verified(
               source,
               target,
               managed_asset("installer", "installer.img", "managed"),
               before_transition: before_transition
             )

    assert File.read!(preserved) == "managed"
    assert File.read!(target) == "operator"
    refute File.exists?(source)
  end

  test "content changed in place after verification is detected after the atomic move", %{
    root: root
  } do
    source = Path.join(root, "installer.img")
    target = Path.join(root, ".installer.tombstone")
    File.write!(source, "managed")

    before_transition = fn ^source, ^target ->
      File.write!(source, "changed")
      :ok
    end

    assert {:error, :source_changed} =
             FileOps.move_verified(
               source,
               target,
               managed_asset("installer", "installer.img", "managed"),
               before_transition: before_transition
             )

    assert File.read!(target) == "changed"
    refute File.exists?(source)
  end

  test "remove never deletes a path replaced after verification", %{root: root} do
    path = Path.join(root, ".installer.tombstone")
    preserved = Path.join(root, "preserved-managed.img")
    asset = managed_asset("installer", "installer.img", "managed")
    File.write!(path, "managed")

    before_remove = fn ^path ->
      File.rename!(path, preserved)
      File.write!(path, "operator")
      :ok
    end

    assert {:error, :source_changed} =
             FileOps.remove_verified(path, asset, before_remove: before_remove)

    assert File.read!(preserved) == "managed"
    assert File.read!(path) == "operator"
  end

  defp managed_asset(asset_id, filename, contents) do
    {:ok, asset} =
      ManagedAsset.from_document(%{
        "asset_id" => asset_id,
        "filename" => filename,
        "size" => byte_size(contents),
        "blob_digest" => sha256(contents),
        "ownership" => "managed",
        "lifecycle" => "active"
      })

    asset
  end

  defp sha256(contents) do
    :crypto.hash(:sha256, contents)
    |> Base.encode16(case: :lower)
  end

  defp unique, do: System.unique_integer([:positive, :monotonic])
end
