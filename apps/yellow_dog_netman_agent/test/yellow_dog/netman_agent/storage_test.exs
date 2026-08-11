defmodule YellowDog.NetmanAgent.StorageTest do
  use ExUnit.Case, async: false

  alias YellowDog.NetmanAgent.Storage
  alias YellowDog.NetmanAgent.Storage.FileOps
  alias YellowDog.Sync.Error
  alias YellowDog.Sync.Message

  defmodule SwappedReadOps do
    @moduledoc false

    def configure(owner, requested_path, opened_path) do
      Process.put({__MODULE__, :state}, {owner, requested_path, opened_path})
    end

    def clear, do: Process.delete({__MODULE__, :state})

    def open(_path, _modes) do
      {_owner, _requested_path, opened_path} = state()
      {:ok, opened_path}
    end

    def read_file_info(opened_path), do: :file.read_file_info(opened_path)

    def read_link_info(_path) do
      {_owner, requested_path, _opened_path} = state()
      :file.read_link_info(requested_path)
    end

    def read(opened_path, _max_bytes) do
      {owner, _requested_path, _opened_path} = state()
      send(owner, :unsafe_descriptor_read)
      File.read(opened_path)
    end

    def close(_opened_path) do
      {owner, _requested_path, _opened_path} = state()
      send(owner, :descriptor_closed)
      :ok
    end

    defp state, do: Process.get({__MODULE__, :state})
  end

  defmodule ZeroIdentityOps do
    @moduledoc false

    def configure(owner), do: Process.put({__MODULE__, :owner}, owner)
    def clear, do: Process.delete({__MODULE__, :owner})
    def open(path, _modes), do: {:ok, path}
    def read_file_info(path), do: zero_identity(:file.read_file_info(path))
    def read_link_info(path), do: zero_identity(:file.read_link_info(path))

    def read(path, _max_bytes) do
      send(Process.get({__MODULE__, :owner}), :unsafe_descriptor_read)
      File.read(path)
    end

    def close(_path) do
      send(Process.get({__MODULE__, :owner}), :descriptor_closed)
      :ok
    end

    defp zero_identity({:ok, info}) do
      {:ok, info |> put_elem(9, 0) |> put_elem(10, 0) |> put_elem(11, 0)}
    end

    defp zero_identity(error), do: error
  end

  defmodule ExplodingReadOps do
    @moduledoc false

    def configure(owner), do: Process.put({__MODULE__, :owner}, owner)
    def clear, do: Process.delete({__MODULE__, :owner})
    def open(_path, _modes), do: {:ok, :device}
    def read_file_info(:device), do: raise("file info exploded")
    def read_link_info(path), do: :file.read_link_info(path)
    def read(_device, _max_bytes), do: raise("unexpected read")

    def close(:device) do
      send(Process.get({__MODULE__, :owner}), :descriptor_closed)
      :ok
    end
  end

  setup do
    data_dir =
      Path.join(
        System.tmp_dir!(),
        "yellow-dog-netman-storage-#{System.unique_integer([:positive])}"
      )
      |> Path.expand()

    File.mkdir_p!(data_dir)

    on_exit(fn ->
      SwappedReadOps.clear()
      ZeroIdentityOps.clear()
      ExplodingReadOps.clear()
      File.rm_rf(data_dir)
    end)

    %{data_dir: data_dir}
  end

  test "rejects a symlink instead of following it", %{data_dir: data_dir} do
    outside_path = Path.join(data_dir, "outside.json")
    symlink_path = Path.join(data_dir, "document.json")
    File.write!(outside_path, ~s({"outside":true}))
    File.ln_s!(outside_path, symlink_path)

    assert {:error, :unsafe_file} = FileOps.read(symlink_path, 1_024)
  end

  test "rejects an opened descriptor whose identity differs from the requested path", %{
    data_dir: data_dir
  } do
    requested_path = Path.join(data_dir, "requested.json")
    opened_path = Path.join(data_dir, "outside.json")
    File.write!(requested_path, ~s({"requested":true}))
    File.write!(opened_path, ~s({"outside":true}))
    SwappedReadOps.configure(self(), requested_path, opened_path)

    assert {:error, :unsafe_file} =
             FileOps.read_with(requested_path, 1_024, SwappedReadOps)

    refute_receive :unsafe_descriptor_read
    assert_receive :descriptor_closed
  end

  test "fails closed when the filesystem has no meaningful file identity", %{
    data_dir: data_dir
  } do
    path = Path.join(data_dir, "document.json")
    File.write!(path, ~s({"ok":true}))
    ZeroIdentityOps.configure(self())

    assert {:error, :unsafe_file} = FileOps.read_with(path, 1_024, ZeroIdentityOps)
    refute_receive :unsafe_descriptor_read
    refute_receive :descriptor_closed
  end

  test "closes an opened descriptor when file inspection raises", %{data_dir: data_dir} do
    path = Path.join(data_dir, "document.json")
    File.write!(path, ~s({"ok":true}))
    ExplodingReadOps.configure(self())

    assert {:error, :file_exception} = FileOps.read_with(path, 1_024, ExplodingReadOps)
    assert_receive :descriptor_closed
  end

  test "rejects max-byte settings above the protocol document policy", %{data_dir: data_dir} do
    path = Path.join(data_dir, "document.json")
    File.write!(path, ~s({"ok":true}))

    assert {:error, %Error{code: :invalid}} =
             Storage.read(path, max_bytes: Message.max_document_bytes() + 1)
  end
end
