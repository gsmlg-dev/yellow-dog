defmodule YellowDog.Tasks.AtomicFileTest do
  use ExUnit.Case, async: true

  alias YellowDog.Tasks.AtomicFile

  @moduletag :tmp_dir

  test "replaces the target file when validation succeeds", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "database.txt")

    assert {:ok, ^path} = AtomicFile.replace(path, "new", fn tmp_path -> File.read(tmp_path) end)
    assert File.read!(path) == "new"
  end

  test "preserves the target file when validation fails", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "database.txt")
    File.write!(path, "old")

    assert {:error, :invalid} = AtomicFile.replace(path, "bad", fn _tmp_path -> {:error, :invalid} end)
    assert File.read!(path) == "old"
  end

  test "preserves the target file when validation returns false", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "database.txt")
    File.write!(path, "old")

    assert {:error, :invalid} = AtomicFile.replace(path, "bad", fn _tmp_path -> false end)
    assert File.read!(path) == "old"
  end
end
