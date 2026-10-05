defmodule YellowDog.Worker.FileOpsDurabilityTest do
  use ExUnit.Case, async: false

  alias YellowDog.Worker.FileOps

  defmodule Backend do
    def open(path, options), do: fault(:open, fn -> :file.open(path, options) end)
    def write(file, bytes), do: fault(:write, fn -> :file.write(file, bytes) end)
    def sync(file), do: fault(:sync, fn -> :file.sync(file) end)

    def close(file) do
      result = :file.close(file)
      send(self(), {:closed, file})
      fault(:close, fn -> result end)
    end

    defp fault(operation, callback) do
      if Process.get(:file_fault) == operation,
        do: {:error, {:injected, operation}},
        else: callback.()
    end
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "file-ops-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  for operation <- [:open, :write, :sync, :close] do
    test "real write_synced wrapper propagates independent #{operation} failure", %{dir: dir} do
      Process.put(:file_fault, unquote(operation))

      assert {:error, {:injected, unquote(operation)}} =
               FileOps.write_synced(Path.join(dir, "candidate"), "complete bytes", Backend)

      if unquote(operation) != :open do
        assert_receive {:closed, file}
        assert {:error, _} = :file.write(file, "must be closed")
      else
        refute_receive {:closed, _}, 0
      end
    end
  end

  test "real exclusive-open, readback, rename and synchronization errors remain concrete", %{
    dir: dir
  } do
    path = Path.join(dir, "existing")
    assert :ok = FileOps.write_synced(path, "bytes")
    assert {:error, :eexist} = FileOps.write_synced(path, "replacement")
    assert {:ok, "bytes"} = FileOps.read(path)
    assert {:error, :enoent} = FileOps.read(Path.join(dir, "missing"))
    assert {:error, :enoent} = FileOps.rename(Path.join(dir, "missing"), path)

    assert {:error, {:sync_failed, status, message}} =
             FileOps.sync_path(Path.join(dir, "missing"))

    assert status != 0
    assert message != ""
  end
end
