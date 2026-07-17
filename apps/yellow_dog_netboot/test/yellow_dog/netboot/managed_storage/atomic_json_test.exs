defmodule YellowDog.Netboot.ManagedStorage.AtomicJsonTest do
  use ExUnit.Case, async: true

  alias YellowDog.Netboot.ManagedStorage.AtomicJson
  alias YellowDog.Netboot.ManagedStorage.TestFileOps

  setup do
    root =
      Path.join(System.tmp_dir!(), "netboot_atomic_json_#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)

    on_exit(fn -> File.rm_rf!(root) end)

    %{root: root}
  end

  test "returns the supplied default when the sidecar is missing", %{root: root} do
    default = %{"version" => 1, "profiles" => []}

    assert {:ok, ^default} = AtomicJson.read(Path.join(root, "missing.json"), default)
  end

  test "reads a JSON object", %{root: root} do
    path = Path.join(root, "managed_profiles.json")
    File.write!(path, ~s({"version":1,"profiles":[]}))

    assert {:ok, %{"version" => 1, "profiles" => []}} = AtomicJson.read(path, %{})
  end

  test "rejects malformed JSON without exposing decoder details", %{root: root} do
    path = Path.join(root, "managed_profiles.json")
    File.write!(path, "{")

    assert {:error, :invalid_json} = AtomicJson.read(path, %{})
  end

  test "rejects a JSON value that is not an object", %{root: root} do
    path = Path.join(root, "managed_profiles.json")
    File.write!(path, "[]")

    assert {:error, :invalid_object} = AtomicJson.read(path, %{})
  end

  test "rejects an oversized sidecar before decoding", %{root: root} do
    path = Path.join(root, "managed_profiles.json")
    File.write!(path, ~s({"version":1}))

    assert {:error, :too_large} = AtomicJson.read(path, %{}, max_bytes: 2)
  end

  test "atomically replaces an existing sidecar from a same-directory temporary file", %{
    root: root
  } do
    path = Path.join([root, "nested", "managed_profiles.json"])

    assert :ok =
             AtomicJson.write(path, %{"version" => 2}, file_ops: {TestFileOps, %{owner: self()}})

    assert File.dir?(Path.dirname(path))
    assert {:ok, %{"version" => 2}} = AtomicJson.read(path, %{})
    assert_receive {:managed_storage_file_op, :open, [temporary_path]}
    assert Path.dirname(temporary_path) == Path.dirname(path)
    assert temporary_path != path
    refute File.exists?(temporary_path)
  end

  for phase <- [:write, :sync, :close, :rename] do
    test "#{phase} failure removes its temporary file and preserves the prior sidecar", %{
      root: root
    } do
      path = Path.join(root, "managed_profiles.json")
      previous = ~s({"version":1})
      File.write!(path, previous)

      assert {:error, unquote(:"#{phase}_failed")} =
               AtomicJson.write(path, %{"version" => 2},
                 file_ops: {TestFileOps, %{fail: unquote(phase)}}
               )

      assert File.read!(path) == previous
      assert [] == Path.wildcard(Path.join(root, ".managed_profiles.json.*.tmp"))
    end
  end
end
