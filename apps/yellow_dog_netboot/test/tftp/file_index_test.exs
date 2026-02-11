defmodule YellowDog.Netboot.TFTP.FileIndexTest do
  use ExUnit.Case, async: false

  alias YellowDog.Netboot.TFTP.FileIndex

  @tmp_root System.tmp_dir!() |> Path.join("netboot_file_index_test")

  setup do
    File.rm_rf!(@tmp_root)
    File.mkdir_p!(Path.join(@tmp_root, "subdir"))
    File.write!(Path.join(@tmp_root, "kernel.img"), "kernel data")
    File.write!(Path.join(@tmp_root, "initrd.img"), "initrd data")
    File.write!(Path.join(@tmp_root, "subdir/nested.bin"), "nested")

    FileIndex.init()
    FileIndex.scan(@tmp_root)

    on_exit(fn -> File.rm_rf!(@tmp_root) end)
    :ok
  end

  describe "scan/1" do
    test "indexes files in root" do
      assert {:ok, 3} = FileIndex.scan(@tmp_root)
    end

    test "returns error for non-existent directory" do
      assert {:error, :not_a_directory} = FileIndex.scan("/nonexistent/path")
    end
  end

  describe "lookup/2" do
    test "finds file by relative path" do
      assert {:ok, abs_path, size} = FileIndex.lookup("kernel.img", @tmp_root)
      assert String.ends_with?(abs_path, "kernel.img")
      assert size == byte_size("kernel data")
    end

    test "finds nested file" do
      assert {:ok, _, _} = FileIndex.lookup("subdir/nested.bin", @tmp_root)
    end

    test "returns not_found for missing file" do
      assert {:error, :not_found} = FileIndex.lookup("nope.bin", @tmp_root)
    end

    test "rejects path traversal with .." do
      assert {:error, :path_traversal} = FileIndex.lookup("../etc/passwd", @tmp_root)
    end

    test "rejects absolute paths" do
      assert {:error, :path_traversal} = FileIndex.lookup("/etc/passwd", @tmp_root)
    end

    test "rejects backslash paths" do
      assert {:error, :path_traversal} = FileIndex.lookup("..\\etc\\passwd", @tmp_root)
    end
  end

  describe "path_traversal?/1" do
    test "detects .." do
      assert FileIndex.path_traversal?("../etc/passwd")
    end

    test "detects absolute path" do
      assert FileIndex.path_traversal?("/etc/passwd")
    end

    test "detects backslash" do
      assert FileIndex.path_traversal?("foo\\bar")
    end

    test "allows normal relative path" do
      refute FileIndex.path_traversal?("subdir/file.img")
    end

    test "allows simple filename" do
      refute FileIndex.path_traversal?("kernel.img")
    end
  end

  describe "list/0 and count/0" do
    test "lists all indexed files" do
      files = FileIndex.list()
      assert length(files) == 3
    end

    test "counts indexed files" do
      assert FileIndex.count() == 3
    end
  end
end
