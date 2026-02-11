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

    test "returns error for nonexistent file", %{store: store} do
      assert {:error, :enoent} =
               GenServer.call(store, {:delete_file, "does_not_exist.bin"})
    end
  end

  describe "get_file" do
    test "returns file info for existing file", %{root: root, store: store} do
      File.write!(Path.join(root, "kernel.bin"), "kernel content")

      assert {:ok, info} = GenServer.call(store, {:get_file, "kernel.bin"})
      assert info.path == "kernel.bin"
      assert info.size == 14
      assert info.type == :file
    end

    test "returns directory info for existing directory", %{root: root, store: store} do
      File.mkdir_p!(Path.join(root, "subdir"))

      assert {:ok, info} = GenServer.call(store, {:get_file, "subdir"})
      assert info.path == "subdir"
      assert info.type == :directory
    end

    test "returns not_found for missing file", %{store: store} do
      assert {:error, :not_found} = GenServer.call(store, {:get_file, "ghost.bin"})
    end

    test "rejects path traversal", %{store: store} do
      assert {:error, :path_traversal} =
               GenServer.call(store, {:get_file, "../../../etc/shadow"})
    end
  end

  describe "root_dir" do
    test "returns configured root directory", %{root: root, store: store} do
      assert GenServer.call(store, :root_dir) == root
    end
  end

  describe "list_files with nested directories" do
    test "recurses into subdirectories", %{root: root, store: store} do
      File.mkdir_p!(Path.join(root, "arch/x86_64"))
      File.write!(Path.join(root, "arch/x86_64/vmlinuz"), "kernel")
      File.write!(Path.join(root, "boot.efi"), "efi")

      files = GenServer.call(store, :list_files)
      paths = Enum.map(files, & &1.path)

      assert "boot.efi" in paths
      assert "arch/x86_64/vmlinuz" in paths
      assert length(files) == 2
    end
  end

  describe "file_tree with empty directory" do
    test "empty root returns empty tree", %{store: store} do
      tree = GenServer.call(store, :file_tree)
      assert tree == []
    end
  end

  describe "upload_file edge cases" do
    test "upload from nonexistent source returns error", %{store: store} do
      assert {:error, :enoent} =
               GenServer.call(store, {:upload_file, "dest.bin", "/nonexistent/source"})
    end

    test "overwrite existing file", %{root: root, store: store} do
      src1 = Path.join(root, "src1")
      src2 = Path.join(root, "src2")
      File.write!(src1, "original")
      File.write!(src2, "updated")

      assert :ok = GenServer.call(store, {:upload_file, "target.bin", src1})
      assert File.read!(Path.join(root, "target.bin")) == "original"

      assert :ok = GenServer.call(store, {:upload_file, "target.bin", src2})
      assert File.read!(Path.join(root, "target.bin")) == "updated"
    end

    test "upload into deeply nested directory", %{root: root, store: store} do
      src = Path.join(root, "deep_src")
      File.write!(src, "deep data")

      assert :ok = GenServer.call(store, {:upload_file, "a/b/c/d/file.bin", src})
      assert File.read!(Path.join(root, "a/b/c/d/file.bin")) == "deep data"
    end
  end

  describe "init/1 defaults" do
    test "uses default root when no config provided" do
      name = :"store_default_#{System.unique_integer([:positive])}"
      {:ok, pid} = GenServer.start_link(Store, [], name: name)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      assert GenServer.call(name, :root_dir) == "/srv/netboot/tftp"
    end
  end

  describe "public API functions (global instance)" do
    test "root_dir/0 returns configured root" do
      root = Store.root_dir()
      assert is_binary(root)
    end

    test "list_files/0 returns a list" do
      files = Store.list_files()
      assert is_list(files)
    end

    test "file_tree/0 returns a list" do
      tree = Store.file_tree()
      assert is_list(tree)
    end

    test "get_file/1 with path traversal" do
      assert {:error, :path_traversal} = Store.get_file("../../../etc/passwd")
    end

    test "get_file/1 with nonexistent file" do
      assert {:error, :not_found} = Store.get_file("nonexistent_file.bin")
    end

    test "delete_file/1 with path traversal" do
      assert {:error, :path_traversal} = Store.delete_file("../../etc/hosts")
    end

    test "upload_file/2 with path traversal" do
      assert {:error, :path_traversal} = Store.upload_file("../../../evil", "/tmp/source")
    end
  end

  describe "list_files with unreadable entries" do
    test "handles empty subdirectories", %{root: root, store: store} do
      File.mkdir_p!(Path.join(root, "empty_dir"))

      files = GenServer.call(store, :list_files)
      # Empty dirs produce no files
      assert files == []
    end
  end

  describe "file_tree with mixed content" do
    test "handles files and directories at multiple levels", %{root: root, store: store} do
      File.write!(Path.join(root, "root.bin"), "root")
      File.mkdir_p!(Path.join(root, "sub"))
      File.write!(Path.join(root, "sub/nested.bin"), "nested")
      File.mkdir_p!(Path.join(root, "sub/deep"))
      File.write!(Path.join(root, "sub/deep/leaf.bin"), "leaf")

      tree = GenServer.call(store, :file_tree)

      # Root level has root.bin + sub directory
      assert length(tree) == 2

      sub_dir = Enum.find(tree, &(&1.name == "sub"))
      assert sub_dir.type == :directory
      assert length(sub_dir.children) == 2

      deep_dir = Enum.find(sub_dir.children, &(&1.name == "deep"))
      assert deep_dir.type == :directory
      assert length(deep_dir.children) == 1
    end
  end
end
