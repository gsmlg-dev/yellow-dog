defmodule YellowDog.Netboot.Asset.ManagedAssetTest do
  use ExUnit.Case, async: true

  alias YellowDog.Netboot.Asset.ManagedAsset

  @digest String.duplicate("a", 64)

  test "loads an active managed asset and projects its wire resource" do
    document = %{
      "asset_id" => "installer",
      "filename" => "images/installer.img",
      "size" => 12,
      "blob_digest" => @digest,
      "ownership" => "managed",
      "lifecycle" => "active"
    }

    assert {:ok, asset} = ManagedAsset.from_document(document)
    assert asset.asset_id == "installer"
    assert asset.filename == "images/installer.img"

    assert ManagedAsset.to_resource(asset) == %{
             "asset_id" => "installer",
             "filename" => "images/installer.img",
             "size" => 12,
             "blob_digest" => @digest
           }
  end

  test "rejects unstable asset IDs" do
    for asset_id <- ["", ".", "..", "~", "../installer", "installer/path", "bad\\id"] do
      assert {:error, :invalid_asset_id} =
               valid_document()
               |> Map.put("asset_id", asset_id)
               |> ManagedAsset.from_document()
    end

    assert {:error, :invalid_asset_id} =
             valid_document()
             |> Map.put("asset_id", String.duplicate("a", 129))
             |> ManagedAsset.from_document()
  end

  test "rejects unsafe or non-normalized relative filenames" do
    invalid = [
      "",
      ".",
      "..",
      "/installer.img",
      "../installer.img",
      "images/../installer.img",
      "images//installer.img",
      "images/./installer.img",
      "images\\installer.img",
      "images/installer.img/",
      "images/" <> <<0>> <> "installer.img"
    ]

    for filename <- invalid do
      assert {:error, :invalid_filename} =
               valid_document()
               |> Map.put("filename", filename)
               |> ManagedAsset.from_document()
    end
  end

  test "rejects out-of-bounds size and malformed digest" do
    for size <- [-1, 9_223_372_036_854_775_808, 1.0, "12"] do
      assert {:error, :invalid_size} =
               valid_document()
               |> Map.put("size", size)
               |> ManagedAsset.from_document()
    end

    for digest <- [String.duplicate("A", 64), String.duplicate("a", 63), "sha256:" <> @digest] do
      assert {:error, :invalid_digest} =
               valid_document()
               |> Map.put("blob_digest", digest)
               |> ManagedAsset.from_document()
    end
  end

  test "rejects unknown ownership, lifecycle, and document fields" do
    assert {:error, :invalid_ownership} =
             valid_document()
             |> Map.put("ownership", "operator")
             |> ManagedAsset.from_document()

    assert {:error, :invalid_lifecycle} =
             valid_document()
             |> Map.put("lifecycle", "deleted")
             |> ManagedAsset.from_document()

    assert {:error, :invalid_asset} =
             valid_document()
             |> Map.put("unexpected", true)
             |> ManagedAsset.from_document()
  end

  test "requires a normalized tombstone filename only in tombstoned state" do
    tombstoned =
      valid_document()
      |> Map.put("lifecycle", "tombstoned")
      |> Map.put("tombstone_filename", ".installer.img.yellowdog-delete")

    assert {:ok, asset} = ManagedAsset.from_document(tombstoned)
    assert asset.lifecycle == :tombstoned

    assert {:error, :invalid_tombstone_filename} =
             tombstoned
             |> Map.put("tombstone_filename", "../installer.img")
             |> ManagedAsset.from_document()

    assert {:error, :invalid_asset} =
             valid_document()
             |> Map.put("tombstone_filename", "installer.img.tombstone")
             |> ManagedAsset.from_document()
  end

  defp valid_document do
    %{
      "asset_id" => "installer",
      "filename" => "installer.img",
      "size" => 12,
      "blob_digest" => @digest,
      "ownership" => "managed",
      "lifecycle" => "active"
    }
  end
end
