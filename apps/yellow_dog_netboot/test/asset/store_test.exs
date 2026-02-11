defmodule YellowDog.Netboot.Asset.StoreTest do
  use ExUnit.Case, async: true

  alias YellowDog.Netboot.Asset.Store

  # Start a separate Store instance with a unique name to avoid conflicts
  # with the supervisor-managed one.
  setup do
    root = Path.join(System.tmp_dir!(), "store_test_#{:rand.uniform(100_000)}")
    File.mkdir_p!(root)

    name = :"store_test_#{:rand.uniform(100_000)}"
    {:ok, pid} = GenServer.start_link(Store, [config: %{tftp_root: root}], name: name)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      File.rm_rf!(root)
    end)

    %{root: root, store: name}
  end

  describe "upload_file" do
    test "copies file to destination", %{root: root, store: store} do
      src = Path.join(root, "src_file")
      File.write!(src, "boot kernel data")

      assert :ok = GenServer.call(store, {:upload_file, "vmlinuz", src})
      assert File.read!(Path.join(root, "vmlinuz")) == "boot kernel data"
    end

    test "creates subdirectories as needed", %{root: root, store: store} do
      src = Path.join(root, "src_initrd")
      File.write!(src, "initrd data")

      assert :ok = GenServer.call(store, {:upload_file, "nixos/initrd", src})
      assert File.read!(Path.join(root, "nixos/initrd")) == "initrd data"
    end

    test "rejects path traversal attempts", %{root: root, store: store} do
      src = Path.join(root, "evil")
      File.write!(src, "bad")

      assert {:error, :path_traversal} =
               GenServer.call(store, {:upload_file, "../../../etc/passwd", src})
    end
  end

  describe "list_files" do
    test "returns empty list for empty root", %{store: store} do
      assert GenServer.call(store, :list_files) == []
    end

    test "returns files with metadata", %{root: root, store: store} do
      File.write!(Path.join(root, "pxelinux.0"), "pxe data")

      files = GenServer.call(store, :list_files)
      assert length(files) == 1
      assert hd(files).path == "pxelinux.0"
      assert hd(files).size == 8
    end
  end

  describe "file_tree" do
    test "builds nested directory tree", %{root: root, store: store} do
      File.mkdir_p!(Path.join(root, "nixos"))
      File.write!(Path.join(root, "nixos/vmlinuz"), "kernel")
      File.write!(Path.join(root, "ipxe.efi"), "efi binary")

      tree = GenServer.call(store, :file_tree)
      assert length(tree) == 2

      dir = Enum.find(tree, &(&1.type == :directory))
      assert dir.name == "nixos"
      assert length(dir.children) == 1
    end
  end

  describe "delete_file" do
    test "removes file from root", %{root: root, store: store} do
      File.write!(Path.join(root, "old_kernel"), "data")

      assert :ok = GenServer.call(store, {:delete_file, "old_kernel"})
      refute File.exists?(Path.join(root, "old_kernel"))
    end

    test "rejects path traversal", %{store: store} do
      assert {:error, :path_traversal} =
               GenServer.call(store, {:delete_file, "../../etc/hosts"})
    end
  end
end
