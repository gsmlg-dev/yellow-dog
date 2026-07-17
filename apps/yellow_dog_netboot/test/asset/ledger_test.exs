defmodule YellowDog.Netboot.Asset.LedgerTest do
  use ExUnit.Case, async: true

  alias YellowDog.Netboot.Asset.Ledger
  alias YellowDog.Netboot.Asset.ManagedAsset

  @digest String.duplicate("b", 64)

  setup do
    root =
      Path.join(System.tmp_dir!(), "netboot_asset_ledger_#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{path: Path.join(root, "managed_assets.json")}
  end

  test "loads an empty ledger when the sidecar does not exist", %{path: path} do
    assert {:ok, %Ledger{assets: %{}}} = Ledger.load(path)
  end

  test "round-trips a versioned ledger across restart", %{path: path} do
    asset = managed_asset("installer", "images/installer.img")
    assert {:ok, ledger} = Ledger.put(Ledger.empty(), asset)

    assert :ok = Ledger.write(path, ledger)
    assert {:ok, loaded} = Ledger.load(path)
    assert {:ok, ^asset} = Ledger.fetch(loaded, "installer")
  end

  test "rejects unsupported versions and malformed envelopes", %{path: path} do
    for document <- [
          %{"version" => 2, "assets" => []},
          %{"version" => 1},
          %{"version" => 1, "assets" => %{}},
          %{"version" => 1, "assets" => [], "unexpected" => true}
        ] do
      File.write!(path, Jason.encode!(document))
      assert {:error, :invalid_ledger} = Ledger.load(path)
    end
  end

  test "rejects duplicate IDs and filenames", %{path: path} do
    duplicate_id = [
      asset_document("installer", "one.img"),
      asset_document("installer", "two.img")
    ]

    File.write!(path, Jason.encode!(%{"version" => 1, "assets" => duplicate_id}))
    assert {:error, :duplicate_asset_id} = Ledger.load(path)

    duplicate_filename = [
      asset_document("installer-one", "installer.img"),
      asset_document("installer-two", "installer.img")
    ]

    File.write!(path, Jason.encode!(%{"version" => 1, "assets" => duplicate_filename}))
    assert {:error, :duplicate_filename} = Ledger.load(path)
  end

  test "validates entries during mutation" do
    assert {:ok, ledger} =
             Ledger.put(Ledger.empty(), managed_asset("installer", "installer.img"))

    assert {:error, :duplicate_asset_id} =
             Ledger.put(ledger, managed_asset("installer", "other.img"))

    assert {:error, :duplicate_filename} =
             Ledger.put(ledger, managed_asset("other", "installer.img"))
  end

  defp managed_asset(asset_id, filename) do
    {:ok, asset} =
      asset_id
      |> asset_document(filename)
      |> ManagedAsset.from_document()

    asset
  end

  defp asset_document(asset_id, filename) do
    %{
      "asset_id" => asset_id,
      "filename" => filename,
      "size" => 12,
      "blob_digest" => @digest,
      "ownership" => "managed",
      "lifecycle" => "active"
    }
  end
end
