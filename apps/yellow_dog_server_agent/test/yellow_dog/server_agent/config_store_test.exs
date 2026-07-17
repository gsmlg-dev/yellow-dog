defmodule YellowDog.ServerAgent.ConfigStoreTest do
  use ExUnit.Case, async: false

  alias YellowDog.ServerAgent.ConfigStore
  alias YellowDog.ServerAgent.Storage
  alias YellowDog.Sync.Digest
  alias YellowDog.Sync.Envelope
  alias YellowDog.Sync.Error

  @server_id "server-east-1"
  @profile "dns_only"

  setup do
    data_dir =
      Path.join(
        System.tmp_dir!(),
        "yellow-dog-server-agent-config-store-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(data_dir)
    on_exit(fn -> File.rm_rf(data_dir) end)
    %{data_dir: data_dir}
  end

  test "stages the first config in the fixed layout and exact document shapes", %{
    data_dir: data_dir
  } do
    store = start_store(data_dir)
    envelope = envelope(1)

    assert {:ok, document} = ConfigStore.stage(envelope, store)
    assert document == immutable_document(envelope)
    assert {:ok, ^document} = ConfigStore.current(store)
    assert {:error, %Error{code: :not_found}} = ConfigStore.previous(store)

    version_path = version_path(data_dir, 1, envelope.payload_digest)
    manifest_path = manifest_path(data_dir)

    assert {:ok, ^document} = Storage.read(version_path)

    assert {:ok,
            %{
              "schema_version" => 1,
              "target_type" => "server",
              "target_id" => @server_id,
              "current" => %{"version" => 1, "digest" => digest},
              "previous" => nil
            } = manifest} = Storage.read(manifest_path)

    assert digest == envelope.payload_digest

    assert Map.keys(manifest) |> Enum.sort() ==
             ["current", "previous", "schema_version", "target_id", "target_type"]
  end

  test "advancing a config shifts only the current pointer to previous", %{data_dir: data_dir} do
    store = start_store(data_dir)
    first = envelope(1)
    second = envelope(2)

    assert {:ok, first_document} = ConfigStore.stage(first, store)
    assert {:ok, second_document} = ConfigStore.stage(second, store)
    assert {:ok, ^second_document} = ConfigStore.current(store)
    assert {:ok, ^first_document} = ConfigStore.previous(store)

    assert {:ok, manifest} = Storage.read(manifest_path(data_dir))
    assert manifest["current"] == %{"version" => 2, "digest" => second.payload_digest}
    assert manifest["previous"] == %{"version" => 1, "digest" => first.payload_digest}
  end

  test "repeating the exact current config is idempotent without churning previous", %{
    data_dir: data_dir
  } do
    store = start_store(data_dir)
    first = envelope(1)
    second = envelope(2)

    assert {:ok, _} = ConfigStore.stage(first, store)
    assert {:ok, second_document} = ConfigStore.stage(second, store)
    assert {:ok, ^second_document} = ConfigStore.stage(second, store)

    assert {:ok, manifest} = Storage.read(manifest_path(data_dir))
    assert manifest["previous"] == %{"version" => 1, "digest" => first.payload_digest}
  end

  test "rejects same-version digest changes and lower versions", %{data_dir: data_dir} do
    store = start_store(data_dir)
    first = envelope(1)
    second = envelope(2)
    changed_second = envelope(2, payload: payload(3))

    assert {:ok, _} = ConfigStore.stage(first, store)
    assert {:ok, _} = ConfigStore.stage(second, store)
    assert {:error, %Error{code: :conflict}} = ConfigStore.stage(changed_second, store)
    assert {:error, %Error{code: :conflict}} = ConfigStore.stage(first, store)
  end

  test "rejects a same filename immutable collision", %{data_dir: data_dir} do
    store = start_store(data_dir)
    delivery = envelope(1)
    path = version_path(data_dir, 1, delivery.payload_digest)

    assert {:ok, ^path} =
             Storage.create(path, %{immutable_document(delivery) | "profile" => "other"})

    assert {:error, %Error{code: :conflict}} = ConfigStore.stage(delivery, store)
    assert {:error, %Error{code: :not_found}} = ConfigStore.current(store)
  end

  test "rejects invalid delivery identity, profile, digest, version, operation, payload, and revision before storage",
       %{
         data_dir: data_dir
       } do
    store = start_store(data_dir)
    delivery = envelope(1)

    invalid_deliveries = [
      %{delivery | target_type: :netman},
      %{delivery | target_id: "server-west-1"},
      %{delivery | config_version: nil},
      %{delivery | config_version: 0},
      %{delivery | payload_digest: String.duplicate("0", 64)},
      %{delivery | operation: "server.runtime.services.start"},
      %{delivery | payload: %{"invalid" => true}},
      %{delivery | expected_revision: "not-a-digest"}
    ]

    for invalid_delivery <- invalid_deliveries do
      assert {:error, %Error{code: :invalid}} = ConfigStore.stage(invalid_delivery, store)
    end

    refute File.exists?(manifest_path(data_dir))
    refute File.exists?(Path.dirname(version_path(data_dir, 1, delivery.payload_digest)))
  end

  test "requires a concrete configured profile", %{data_dir: data_dir} do
    assert {:error, :invalid_options} =
             ConfigStore.start_link(
               data_dir: data_dir,
               server_id: @server_id,
               profile: "",
               name: unique_name()
             )
  end

  test "fails closed for tampered manifest pointers and immutable documents", %{
    data_dir: data_dir
  } do
    store = start_store(data_dir)
    delivery = envelope(1)
    assert {:ok, _} = ConfigStore.stage(delivery, store)

    assert {:ok, manifest} = Storage.read(manifest_path(data_dir))

    tampered_manifest = put_in(manifest, ["current", "digest"], String.duplicate("f", 64))
    assert {:ok, _} = Storage.replace(manifest_path(data_dir), tampered_manifest)
    assert {:error, %Error{code: :invalid}} = ConfigStore.current(store)

    assert {:ok, _} = Storage.replace(manifest_path(data_dir), manifest)
    path = version_path(data_dir, 1, delivery.payload_digest)
    assert {:ok, version} = Storage.read(path)
    assert {:ok, _} = Storage.replace(path, %{version | "published_at" => "not-a-time"})
    assert {:error, %Error{code: :invalid}} = ConfigStore.current(store)

    assert {:ok, _} = Storage.replace(path, %{version | "profile" => "cloud_dns"})
    assert {:error, %Error{code: :invalid}} = ConfigStore.current(store)
  end

  test "fails closed staging N+1 after the current immutable document is deleted", %{
    data_dir: data_dir
  } do
    store = start_store(data_dir)
    first = envelope(1)
    second = envelope(2)
    incoming = envelope(3)

    assert {:ok, _} = ConfigStore.stage(first, store)
    assert {:ok, _} = ConfigStore.stage(second, store)
    assert {:ok, manifest} = Storage.read(manifest_path(data_dir))
    File.rm!(version_path(data_dir, 2, second.payload_digest))

    assert {:error, %Error{code: :invalid}} = ConfigStore.stage(incoming, store)
    assert {:ok, ^manifest} = Storage.read(manifest_path(data_dir))
    refute File.exists?(version_path(data_dir, 3, incoming.payload_digest))
  end

  test "fails closed staging N+1 after the current immutable document is corrupt or mismatched",
       %{
         data_dir: data_dir
       } do
    for {name, replacement} <- [
          {"corrupt", %{"invalid" => true}},
          {"mismatched", %{"target_id" => "server-west-1"}}
        ] do
      test_data_dir = Path.join(data_dir, name)
      store = start_store(test_data_dir)
      first = envelope(1)
      second = envelope(2)
      incoming = envelope(3)

      assert {:ok, _} = ConfigStore.stage(first, store)
      assert {:ok, _} = ConfigStore.stage(second, store)
      assert {:ok, manifest} = Storage.read(manifest_path(test_data_dir))
      current_path = version_path(test_data_dir, 2, second.payload_digest)
      assert {:ok, current} = Storage.read(current_path)
      assert {:ok, _} = Storage.replace(current_path, Map.merge(current, replacement))

      assert {:error, %Error{code: :invalid}} = ConfigStore.stage(incoming, store)
      assert {:ok, ^manifest} = Storage.read(manifest_path(test_data_dir))
      refute File.exists?(version_path(test_data_dir, 3, incoming.payload_digest))
    end
  end

  test "fails closed staging N+1 after the previous immutable document is corrupt or missing", %{
    data_dir: data_dir
  } do
    for name <- ["corrupt", "missing"] do
      test_data_dir = Path.join(data_dir, name)
      store = start_store(test_data_dir)
      first = envelope(1)
      second = envelope(2)
      incoming = envelope(3)

      assert {:ok, _} = ConfigStore.stage(first, store)
      assert {:ok, _} = ConfigStore.stage(second, store)
      assert {:ok, manifest} = Storage.read(manifest_path(test_data_dir))
      previous_path = version_path(test_data_dir, 1, first.payload_digest)

      case name do
        "corrupt" -> assert {:ok, _} = Storage.replace(previous_path, %{"invalid" => true})
        "missing" -> assert :ok = File.rm(previous_path)
      end

      assert {:error, %Error{code: :invalid}} = ConfigStore.stage(incoming, store)
      assert {:ok, ^manifest} = Storage.read(manifest_path(test_data_dir))
      refute File.exists?(version_path(test_data_dir, 3, incoming.payload_digest))
    end
  end

  test "rejects cross-id, cross-target, corrupt, and missing persisted state", %{
    data_dir: data_dir
  } do
    store = start_store(data_dir)
    delivery = envelope(1)
    assert {:ok, _} = ConfigStore.stage(delivery, store)

    assert {:ok, manifest} = Storage.read(manifest_path(data_dir))

    assert {:ok, _} =
             Storage.replace(manifest_path(data_dir), %{manifest | "target_id" => "server-west-1"})

    assert {:error, %Error{code: :invalid}} = ConfigStore.current(store)

    assert {:ok, _} = Storage.replace(manifest_path(data_dir), manifest)
    path = version_path(data_dir, 1, delivery.payload_digest)
    assert {:ok, version} = Storage.read(path)
    assert {:ok, _} = Storage.replace(path, %{version | "target_type" => "netman"})
    assert {:error, %Error{code: :invalid}} = ConfigStore.current(store)

    File.write!(manifest_path(data_dir), "{")
    assert {:error, %Error{code: :invalid}} = ConfigStore.current(store)

    File.rm!(manifest_path(data_dir))
    assert {:error, %Error{code: :not_found}} = ConfigStore.current(store)
  end

  test "never selects an orphan after a failed manifest update and preserves the prior manifest",
       %{
         data_dir: data_dir
       } do
    store =
      start_store(data_dir, storage_opts: [file_ops: YellowDog.ServerAgent.FailManifestFileOps])

    first = envelope(1)
    second = envelope(2)

    assert {:ok, first_document} = ConfigStore.stage(first, store)
    assert {:error, %Error{code: :internal}} = ConfigStore.stage(second, store)
    assert File.exists?(version_path(data_dir, 2, second.payload_digest))
    assert {:ok, ^first_document} = ConfigStore.current(store)
    assert {:error, %Error{code: :not_found}} = ConfigStore.previous(store)
  end

  test "returns typed storage timeout and preserves the prior manifest", %{data_dir: data_dir} do
    store =
      start_store(data_dir,
        storage_opts: [file_ops: YellowDog.ServerAgent.TimeoutManifestFileOps]
      )

    first = envelope(1)
    second = envelope(2)

    assert {:ok, first_document} = ConfigStore.stage(first, store)
    assert {:error, %Error{code: :timeout}} = ConfigStore.stage(second, store)
    assert {:ok, ^first_document} = ConfigStore.current(store)
  end

  test "reads staged pointers after a store restart", %{data_dir: data_dir} do
    name = unique_name()
    store = start_store(data_dir, name: name)
    delivery = envelope(1)
    assert {:ok, document} = ConfigStore.stage(delivery, store)

    stop_store(store)
    restarted = start_store(data_dir, name: name)
    assert {:ok, ^document} = ConfigStore.current(restarted)
  end

  defp start_store(data_dir, opts \\ []) do
    name = Keyword.get(opts, :name, unique_name())

    {:ok, pid} =
      ConfigStore.start_link(
        [
          name: name,
          data_dir: data_dir,
          server_id: @server_id,
          profile: @profile
        ] ++ Keyword.drop(opts, [:name])
      )

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    end)

    name
  end

  defp stop_store(store) do
    GenServer.stop(store, :normal)
  end

  defp unique_name, do: {:global, {__MODULE__, System.unique_integer([:positive])}}

  defp envelope(version, opts \\ []) do
    payload = Keyword.get(opts, :payload, %{"service" => "dns", "entries" => []})
    {:ok, digest} = Digest.calculate(payload)

    %Envelope{
      protocol_version: 1,
      request_id: "00000000-0000-4000-8000-00000000000#{version}",
      target_type: Keyword.get(opts, :target_type, :server),
      target_id: Keyword.get(opts, :target_id, @server_id),
      operation: Keyword.get(opts, :operation, "server.settings.update"),
      idempotency_key: "10000000-0000-4000-8000-00000000000#{version}",
      payload: payload,
      payload_digest: Keyword.get(opts, :payload_digest, digest),
      expected_revision: Keyword.get(opts, :expected_revision, nil),
      config_version: Keyword.get(opts, :config_version, version),
      sent_at: ~U[2026-07-17 12:00:00Z]
    }
  end

  defp immutable_document(envelope) do
    %{
      "schema_version" => 1,
      "target_type" => "server",
      "target_id" => @server_id,
      "version" => envelope.config_version,
      "operation" => envelope.operation,
      "profile" => @profile,
      "payload" => envelope.payload,
      "digest" => envelope.payload_digest,
      "expected_revision" => envelope.expected_revision,
      "published_at" => DateTime.to_iso8601(envelope.sent_at)
    }
  end

  defp payload(value) do
    %{
      "service" => "dns",
      "entries" => [
        %{"key" => "timeout", "value" => %{"type" => "integer", "value" => value}}
      ]
    }
  end

  defp manifest_path(data_dir), do: Path.join([data_dir, "server", "manifest.json"])

  defp version_path(data_dir, version, digest),
    do: Path.join([data_dir, "server", "versions", "#{version}-#{digest}.json"])
end

defmodule YellowDog.ServerAgent.FailManifestFileOps do
  @behaviour YellowDog.ServerAgent.Storage.FileOps

  alias YellowDog.ServerAgent.Storage.FileOps

  defdelegate read(path, max_bytes), to: FileOps
  defdelegate mkdir_p(path), to: FileOps
  defdelegate exists?(path), to: FileOps
  defdelegate open(path), to: FileOps
  defdelegate write(device, contents), to: FileOps
  defdelegate sync(device), to: FileOps
  defdelegate close(device), to: FileOps
  defdelegate link(source, target), to: FileOps
  defdelegate rm(path), to: FileOps
  defdelegate same_file?(source, target), to: FileOps
  defdelegate sync_dir(path), to: FileOps

  def rename(source, target) do
    if Path.basename(target) == "manifest.json" and File.exists?(target) do
      {:error, :eio}
    else
      FileOps.rename(source, target)
    end
  end
end

defmodule YellowDog.ServerAgent.TimeoutManifestFileOps do
  @behaviour YellowDog.ServerAgent.Storage.FileOps

  alias YellowDog.ServerAgent.Storage.FileOps

  defdelegate read(path, max_bytes), to: FileOps
  defdelegate mkdir_p(path), to: FileOps
  defdelegate exists?(path), to: FileOps
  defdelegate open(path), to: FileOps
  defdelegate write(device, contents), to: FileOps
  defdelegate sync(device), to: FileOps
  defdelegate close(device), to: FileOps
  defdelegate link(source, target), to: FileOps
  defdelegate rm(path), to: FileOps
  defdelegate same_file?(source, target), to: FileOps
  defdelegate sync_dir(path), to: FileOps

  def rename(source, target) do
    if Path.basename(target) == "manifest.json" and File.exists?(target) do
      {:error, :timeout}
    else
      FileOps.rename(source, target)
    end
  end
end
