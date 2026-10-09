defmodule YellowDog.Worker.CredentialsTest do
  use ExUnit.Case, async: true
  alias YellowDog.Worker.LocalStore
  @moduletag :tmp_dir

  test "noncanonical saved base64 credentials fail closed without changing bytes", %{tmp_dir: dir} do
    {:ok, store} = LocalStore.start_link(data_dir: dir)
    assert {:ok, credentials} = LocalStore.connection_credentials(store, "http://10.8.0.1")
    path = Path.join(dir, "connection.toml")
    damaged = String.replace(File.read!(path), credentials.token, String.duplicate("a", 43))
    File.write!(path, damaged)

    assert {:error, :invalid_credentials} =
             LocalStore.connection_credentials(store, "http://10.8.0.1")

    assert File.read!(path) == damaged
    GenServer.stop(store)
  end

  test "missing credentials beside a committed snapshot never create a new identity", %{
    tmp_dir: dir
  } do
    {:ok, store} = LocalStore.start_link(data_dir: dir)

    plan = %{
      "schema_version" => 1,
      "worker_id" => "edge-01",
      "revision" => 1,
      "services" => [],
      "resources" => []
    }

    assert {:ok, candidate} = LocalStore.prepare(store, plan)
    assert :ok = LocalStore.commit(store, candidate)

    assert {:error, :missing_credentials_for_existing_state} =
             LocalStore.connection_credentials(store, "http://10.8.0.1")

    refute File.exists?(Path.join(dir, "connection.toml"))
    assert {:ok, ^plan} = LocalStore.recover(store)
    GenServer.stop(store)
  end

  defmodule WriteFailure do
    def write_private_synced(_, _), do: {:error, :enospc}
  end

  defmodule SyncFailure do
    defdelegate write_private_synced(path, bytes), to: YellowDog.Worker.FileOps
    defdelegate rename(source, target), to: YellowDog.Worker.FileOps

    def sync_path(path) do
      if Path.basename(path) == "connection.toml" or File.dir?(path),
        do: {:error, :injected_sync},
        else: YellowDog.Worker.FileOps.sync_path(path)
    end
  end

  test "write failures do not create credentials", %{tmp_dir: dir} do
    {:ok, store} = LocalStore.start_link(data_dir: dir, file_ops: WriteFailure)

    assert {:error, :credential_persistence_failed} =
             LocalStore.connection_credentials(store, "http://10.8.0.1")

    refute File.exists?(Path.join(dir, "connection.toml"))
    GenServer.stop(store)
  end

  test "post-rename uncertainty preserves identity until successful durable re-sync", %{
    tmp_dir: dir
  } do
    {:ok, store} = LocalStore.start_link(data_dir: dir, file_ops: SyncFailure)

    assert {:error, :credential_persistence_failed} =
             LocalStore.connection_credentials(store, "http://10.8.0.1")

    bytes = File.read!(Path.join(dir, "connection.toml"))

    assert {:error, :invalid_credentials} =
             LocalStore.connection_credentials(store, "http://10.8.0.1")

    assert File.read!(Path.join(dir, "connection.toml")) == bytes
    GenServer.stop(store)
    {:ok, store} = LocalStore.start_link(data_dir: dir)
    assert {:ok, credentials} = LocalStore.connection_credentials(store, "http://10.8.0.1")
    assert bytes =~ credentials.token
    assert File.read!(Path.join(dir, "connection.toml")) == bytes
    GenServer.stop(store)
  end

  test "credentials survive restart privately and reject another origin", %{tmp_dir: dir} do
    {:ok, store} = LocalStore.start_link(data_dir: dir)
    assert {:ok, credentials} = LocalStore.connection_credentials(store, "http://10.8.0.1:4270")
    assert byte_size(credentials.token) == 43
    assert Regex.match?(~r/\A[0-9a-f-]{36}\z/, credentials.worker_id)
    assert {:ok, ^credentials} = LocalStore.connection_credentials(store, "http://10.8.0.1:4270/")
    refute inspect(:sys.get_status(store)) =~ credentials.token
    GenServer.stop(store)
    {:ok, store} = LocalStore.start_link(data_dir: dir)
    assert {:ok, ^credentials} = LocalStore.connection_credentials(store, "http://10.8.0.1:4270")

    assert {:error, :credential_origin_mismatch} =
             LocalStore.connection_credentials(store, "http://10.8.0.2:4270")

    assert {:ok, %{mode: mode}} = File.stat(Path.join(dir, "connection.toml"))
    assert Bitwise.band(mode, 0o777) == 0o600
    assert {:ok, %{mode: mode}} = File.stat(dir)
    assert Bitwise.band(mode, 0o777) == 0o700
    GenServer.stop(store)
  end

  test "damaged and symlink credentials are never replaced", %{tmp_dir: dir} do
    {:ok, store} = LocalStore.start_link(data_dir: dir)
    path = Path.join(dir, "connection.toml")
    File.write!(path, "damaged")
    File.chmod!(path, 0o600)

    assert {:error, :invalid_credentials} =
             LocalStore.connection_credentials(store, "http://10.8.0.1")

    assert File.read!(path) == "damaged"
    File.rm!(path)
    File.write!(Path.join(dir, "outside"), "damaged")
    File.ln_s!(Path.join(dir, "outside"), path)

    assert {:error, :invalid_credentials} =
             LocalStore.connection_credentials(store, "http://10.8.0.1")

    assert File.read!(path) == "damaged"
    GenServer.stop(store)
  end
end
