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
      assert FileIndex.count() == 3
    end
  end

  describe "owner snapshots" do
    test "build_snapshot/2 is deterministic and does not mutate the active index" do
      File.write!(Path.join(@tmp_root, "new.bin"), "new")

      assert {:ok, snapshot} = FileIndex.build_snapshot(@tmp_root)
      assert snapshot == Enum.sort(snapshot)

      assert Enum.map(snapshot, &elem(&1, 0)) == [
               "initrd.img",
               "kernel.img",
               "new.bin",
               "subdir/nested.bin"
             ]

      assert FileIndex.count() == 3
      assert {:error, :not_found} = FileIndex.lookup("new.bin", @tmp_root)
    end

    test "build_snapshot/2 excludes only exact normalized filenames" do
      File.write!(Path.join(@tmp_root, ".kernel.img.yellowdog-delete"), "tombstone")

      assert {:ok, snapshot} =
               FileIndex.build_snapshot(@tmp_root,
                 exclude: [".kernel.img.yellowdog-delete"]
               )

      filenames = Enum.map(snapshot, &elem(&1, 0))
      refute ".kernel.img.yellowdog-delete" in filenames
      assert "kernel.img" in filenames
    end

    test "snapshot/0 and replace/1 support deterministic compensation" do
      previous = FileIndex.snapshot()
      replacement = [{"only.bin", Path.join(@tmp_root, "only.bin"), 10}]

      assert :ok = FileIndex.replace(replacement)
      assert FileIndex.snapshot() == replacement

      assert :ok = FileIndex.replace(previous)
      assert FileIndex.snapshot() == previous
    end

    test "replace/1 rejects malformed snapshots without changing the active index" do
      previous = FileIndex.snapshot()

      assert {:error, :invalid_snapshot} =
               FileIndex.replace([{"../escape", "/tmp/escape", 1}])

      assert FileIndex.snapshot() == previous
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

  describe "init/0" do
    test "calling init twice is idempotent" do
      assert :ok = FileIndex.init()
      assert FileIndex.count() == 3
    end
  end

  describe "scan/1 edge cases" do
    test "rescans and replaces previous index" do
      File.write!(Path.join(@tmp_root, "new_file.bin"), "new data")
      assert {:ok, 4} = FileIndex.scan(@tmp_root)
      assert FileIndex.count() == 4
    end

    test "handles empty directory" do
      empty = Path.join(System.tmp_dir!(), "empty_scan_#{System.unique_integer([:positive])}")
      File.mkdir_p!(empty)
      on_exit(fn -> File.rm_rf!(empty) end)

      assert {:ok, 0} = FileIndex.scan(empty)
    end

    test "skips non-regular files (directories only)" do
      dir_only = Path.join(System.tmp_dir!(), "dir_only_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(dir_only, "a/b/c"))
      on_exit(fn -> File.rm_rf!(dir_only) end)

      assert {:ok, 0} = FileIndex.scan(dir_only)
    end
  end

  describe "lookup/2 edge cases" do
    test "lookup with leading slash is path traversal" do
      assert {:error, :path_traversal} = FileIndex.lookup("/kernel.img", @tmp_root)
    end

    test "normalizes backslash-separated paths to forward slash" do
      # The normalize_path function converts backslashes to forward slashes
      # So "subdir\nested.bin" -> "subdir/nested.bin" which should be found
      # but the path_traversal? check catches backslashes first
      assert {:error, :path_traversal} = FileIndex.lookup("subdir\\nested.bin", @tmp_root)
    end
  end

  describe "scan_recursive with symlinks" do
    test "skips symlinks pointing to non-existent files" do
      sym_root =
        Path.join(System.tmp_dir!(), "symlink_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(sym_root)
      File.write!(Path.join(sym_root, "real.txt"), "data")

      # Create a symlink to non-existent target
      sym_path = Path.join(sym_root, "broken_link")
      File.ln_s("/nonexistent/target", sym_path)

      on_exit(fn -> File.rm_rf!(sym_root) end)

      assert {:ok, count} = FileIndex.scan(sym_root)
      # Only the real file should be indexed, broken symlink skipped
      assert count == 1
    end
  end
end
