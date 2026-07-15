defmodule YellowDog.Management.Storage.PathTest do
  use ExUnit.Case, async: false

  alias YellowDog.Management.Storage.Path, as: StoragePath

  @digest String.duplicate("a", 64)

  setup do
    previous_data_dir = Application.get_env(:yellow_dog_management_core, :data_dir)

    data_dir =
      Path.join(
        System.tmp_dir!(),
        "yellow-dog-management-path-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:yellow_dog_management_core, :data_dir, data_dir)

    on_exit(fn ->
      restore_data_dir(previous_data_dir)
      File.rm_rf(data_dir)
    end)

    %{data_dir: data_dir}
  end

  test "constructs every management path below the configured root", %{data_dir: data_dir} do
    root = Path.join(data_dir, "management")

    assert {:ok, ^root} = StoragePath.root()

    server_manifest = Path.join([root, "servers", "server-01", "manifest.json"])
    assert {:ok, ^server_manifest} = StoragePath.server_manifest("server-01")

    server_version = Path.join([root, "servers", "server-01", "versions", "7-#{@digest}.json"])
    assert {:ok, ^server_version} = StoragePath.server_version("server-01", 7, @digest)

    netman_manifest = Path.join([root, "netmans", "netman-01", "manifest.json"])
    assert {:ok, ^netman_manifest} = StoragePath.netman_manifest("netman-01")

    netman_version = Path.join([root, "netmans", "netman-01", "versions", "7-#{@digest}.json"])
    assert {:ok, ^netman_version} = StoragePath.netman_version("netman-01", 7, @digest)

    command = Path.join([root, "commands", "d2d2d2d2-1111-2222-3333-444444444444.json"])
    assert {:ok, ^command} = StoragePath.command("d2d2d2d2-1111-2222-3333-444444444444")

    event = Path.join([root, "events", "evt-42.json"])
    assert {:ok, ^event} = StoragePath.event("evt-42")

    server_snapshot = Path.join([root, "snapshots", "servers", "server-01", "example.com.json"])
    assert {:ok, ^server_snapshot} = StoragePath.server_snapshot("server-01", "example.com")

    netman_snapshot = Path.join([root, "snapshots", "netmans", "netman-01", "example.com.json"])
    assert {:ok, ^netman_snapshot} = StoragePath.netman_snapshot("netman-01", "example.com")

    blob = Path.join([root, "blobs", @digest])
    assert {:ok, ^blob} = StoragePath.blob(@digest)
  end

  test "rejects unsafe IDs without constructing a path outside the management root" do
    for id <- [
          "",
          ".",
          "..",
          "/etc/passwd",
          "C:\\\\windows",
          "server/child",
          "server\\\\child",
          "../escape",
          "server\uFF0Fchild",
          "server\uFF3Cchild",
          "line\nfeed",
          <<255>>,
          String.duplicate("x", 129)
        ] do
      assert_invalid(StoragePath.server_manifest(id))
    end
  end

  test "accepts only canonical concrete request IDs, event IDs, versions, domains, and digests" do
    assert_invalid(StoragePath.command("D2D2D2D2-1111-2222-3333-444444444444"))
    assert_invalid(StoragePath.command("not-a-uuid"))
    assert_invalid(StoragePath.event("evt-0"))
    assert_invalid(StoragePath.event("evt-42/other"))
    assert_invalid(StoragePath.server_version("server-01", -1, @digest))
    assert_invalid(StoragePath.server_version("server-01", "7", @digest))
    assert_invalid(StoragePath.server_version("server-01", 7, String.upcase(@digest)))
    assert_invalid(StoragePath.server_snapshot("server-01", "Example.com"))
    assert_invalid(StoragePath.server_snapshot("server-01", "example.com."))
    assert_invalid(StoragePath.server_snapshot("server-01", "example..com"))
    assert_invalid(StoragePath.server_snapshot("server-01", "example/com"))
    assert_invalid(StoragePath.blob("not-a-digest"))
  end

  defp assert_invalid(result) do
    assert {:error, %{code: :invalid}} = result
  end

  defp restore_data_dir(nil), do: Application.delete_env(:yellow_dog_management_core, :data_dir)

  defp restore_data_dir(value),
    do: Application.put_env(:yellow_dog_management_core, :data_dir, value)
end
