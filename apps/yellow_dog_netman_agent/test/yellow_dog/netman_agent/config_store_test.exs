defmodule YellowDog.NetmanAgent.ConfigStoreTest do
  use ExUnit.Case, async: false

  alias YellowDog.NetmanAgent.ConfigStore
  alias YellowDog.NetmanAgent.Storage
  alias YellowDog.Sync.Digest
  alias YellowDog.Sync.Envelope
  alias YellowDog.Sync.Error
  alias YellowDog.Sync.Message

  @netman_id "netman-east-1"

  setup do
    trap_exit = Process.flag(:trap_exit, true)

    data_dir =
      Path.join(
        System.tmp_dir!(),
        "yellow-dog-netman-config-#{System.unique_integer([:positive])}"
      )
      |> Path.expand()

    File.mkdir_p!(data_dir)

    on_exit(fn ->
      Process.flag(:trap_exit, trap_exit)
      File.rm_rf(data_dir)
    end)

    %{data_dir: data_dir}
  end

  test "stages immutable versions and exposes current then previous manifests", %{
    data_dir: data_dir
  } do
    store = start_store(data_dir)
    first = envelope(1)

    second = envelope(2, payload: payload("office"))

    assert {:ok, first_document} = ConfigStore.stage(first, store)
    assert {:ok, second_document} = ConfigStore.stage(second, store)
    assert {:ok, ^second_document} = ConfigStore.current(store)
    assert {:ok, ^first_document} = ConfigStore.previous(store)

    assert {:ok, manifest} = Storage.read(manifest_path(data_dir))
    assert manifest["target_type"] == "netman"
    assert manifest["target_id"] == @netman_id
    assert manifest["current"]["version"] == 2
    assert manifest["previous"]["version"] == 1
  end

  test "fetches an exact immutable version after it is no longer the manifest previous", %{
    data_dir: data_dir
  } do
    store = start_store(data_dir)
    first = envelope(1)
    second = envelope(2, payload: payload("office"))
    third = envelope(3, payload: payload("lab"))

    assert {:ok, first_document} = ConfigStore.stage(first, store)
    assert {:ok, _second_document} = ConfigStore.stage(second, store)
    assert {:ok, _third_document} = ConfigStore.stage(third, store)

    assert {:ok, ^first_document} = ConfigStore.fetch(1, first.payload_digest, store)

    assert {:error, %Error{code: :invalid}} =
             ConfigStore.fetch(1, String.duplicate("f", 64), store)
  end

  test "finds a durable config by installed revision after newer deliveries and restart", %{
    data_dir: data_dir
  } do
    name = unique_name()
    store = start_store(data_dir, name: name)
    first = envelope(1)

    assert {:ok, first_document} = ConfigStore.stage(first, store)

    assert {:ok, _second_document} =
             ConfigStore.stage(envelope(2, payload: payload("office")), store)

    assert {:ok, _third_document} = ConfigStore.stage(envelope(3, payload: payload("lab")), store)

    assert {:ok, ^first_document} =
             ConfigStore.fetch_revision(first.payload_digest, store)

    stop(store)
    restarted = start_store(data_dir, name: name)

    assert {:ok, ^first_document} =
             ConfigStore.fetch_revision(first.payload_digest, restarted)

    assert {:error, %Error{code: :not_found}} =
             ConfigStore.fetch_revision(String.duplicate("f", 64), restarted)
  end

  test "persists exact operation-specific restore checkpoints across restart", %{
    data_dir: data_dir
  } do
    name = unique_name()
    store = start_store(data_dir, name: name)

    delivery =
      envelope(1,
        operation: "netman.resolved.config.update",
        payload: %{"upstreams" => ["192.0.2.53"], "search_domains" => ["example.test"]}
      )

    checkpoint = %{
      operation: "netman.resolved.config.rollback",
      payload: %{"target_revision" => String.duplicate("a", 64)}
    }

    assert {:ok, _document} = ConfigStore.stage(delivery, store)

    assert :ok =
             ConfigStore.put_restore_checkpoint(
               delivery.config_version,
               delivery.payload_digest,
               checkpoint,
               store
             )

    assert {:ok, stored} = ConfigStore.fetch_restore_checkpoint(delivery.payload_digest, store)
    assert stored["candidate_operation"] == delivery.operation
    assert stored["restore_operation"] == checkpoint.operation
    assert stored["restore_payload"] == checkpoint.payload

    assert :ok =
             ConfigStore.put_restore_checkpoint(
               delivery.config_version,
               delivery.payload_digest,
               checkpoint,
               store
             )

    stop(store)
    restarted = start_store(data_dir, name: name)

    assert {:ok, ^stored} =
             ConfigStore.fetch_restore_checkpoint(delivery.payload_digest, restarted)

    assert {:error, %Error{code: :invalid}} =
             ConfigStore.put_restore_checkpoint(
               delivery.config_version,
               delivery.payload_digest,
               %{operation: "netman.profiles.replace", payload: %{"profiles" => []}},
               restarted
             )

    stop(restarted)
    File.write!(restore_checkpoint_path(data_dir, delivery), "{")

    assert {:error, {:config_recovery_failed, %Error{code: :invalid}}} =
             ConfigStore.start_link(
               name: unique_name(),
               data_dir: data_dir,
               netman_id: @netman_id
             )
  end

  test "preserves an immutable config version across a restart", %{data_dir: data_dir} do
    name = unique_name()
    store = start_store(data_dir, name: name)
    delivery = envelope(1)

    assert {:ok, document} = ConfigStore.stage(delivery, store)
    stop(store)

    restarted = start_store(data_dir, name: name)
    assert {:ok, ^document} = ConfigStore.current(restarted)
  end

  test "rejects corrupt manifest and referenced versions during restart", %{data_dir: data_dir} do
    name = unique_name()
    store = start_store(data_dir, name: name)

    assert {:ok, _first} = ConfigStore.stage(envelope(1), store)

    assert {:ok, _second} =
             ConfigStore.stage(
               envelope(2, payload: payload("office")),
               store
             )

    stop(store)
    manifest_path = manifest_path(data_dir)
    manifest_contents = File.read!(manifest_path)
    manifest = Jason.decode!(manifest_contents)

    current_path = version_path(data_dir, manifest["current"])
    previous_path = version_path(data_dir, manifest["previous"])

    for path <- [manifest_path, current_path, previous_path] do
      original = File.read!(path)
      File.write!(path, "{")

      assert {:error, {:config_recovery_failed, %Error{code: :invalid}}} =
               ConfigStore.start_link(
                 name: unique_name(),
                 data_dir: data_dir,
                 netman_id: @netman_id
               )

      File.write!(path, original)
    end
  end

  test "rejects unsafe identities and unbounded storage settings", %{data_dir: data_dir} do
    for invalid_id <- [".", "..", "nested/netman", "nested\\netman", "C:netman", "e\u0301"] do
      assert {:error, :invalid_options} =
               ConfigStore.start_link(
                 name: unique_name(),
                 data_dir: data_dir,
                 netman_id: invalid_id
               )
    end

    assert {:error, :invalid_options} =
             ConfigStore.start_link(
               name: unique_name(),
               data_dir: data_dir,
               netman_id: @netman_id,
               max_bytes: Message.max_document_bytes() + 1
             )

    for max_versions <- [0, 1_025] do
      assert {:error, :invalid_options} =
               ConfigStore.start_link(
                 name: unique_name(),
                 data_dir: data_dir,
                 netman_id: @netman_id,
                 max_versions: max_versions
               )
    end
  end

  test "accepts exactly the three Netman config operations", %{data_dir: data_dir} do
    store = start_store(data_dir)

    deliveries = [
      envelope(1),
      envelope(2,
        operation: "netman.resolved.config.update",
        payload: %{"upstreams" => [], "search_domains" => []}
      ),
      envelope(3,
        operation: "netman.resolved.config.rollback",
        payload: %{"target_revision" => String.duplicate("a", 64)}
      )
    ]

    for delivery <- deliveries do
      assert {:ok, %{"operation" => operation}} = ConfigStore.stage(delivery, store)
      assert operation == delivery.operation
    end
  end

  test "rejects incorrect digests, target identities, and non-config operations before storage",
       %{
         data_dir: data_dir
       } do
    store = start_store(data_dir)
    delivery = envelope(1)

    for invalid <- [
          %{delivery | payload_digest: String.duplicate("0", 64)},
          %{delivery | target_id: "netman-west-1"},
          %{delivery | target_type: :server},
          envelope(2,
            operation: "netman.profiles.put",
            payload: payload("office")["profiles"] |> hd()
          )
        ] do
      assert {:error, %Error{code: :invalid}} = ConfigStore.stage(invalid, store)
    end

    refute File.exists?(manifest_path(data_dir))
  end

  test "rejects same-version digest changes and out-of-order versions", %{data_dir: data_dir} do
    store = start_store(data_dir)
    first = envelope(1)
    second = envelope(2, payload: payload("office"))
    changed_second = envelope(2, payload: payload("lab"))

    assert {:ok, _} = ConfigStore.stage(first, store)
    assert {:ok, _} = ConfigStore.stage(second, store)
    assert {:error, %Error{code: :conflict}} = ConfigStore.stage(changed_second, store)
    assert {:error, %Error{code: :conflict}} = ConfigStore.stage(first, store)
  end

  test "bounds immutable version count without rejecting an exact replay", %{data_dir: data_dir} do
    store = start_store(data_dir, max_versions: 2)
    first = envelope(1)
    second = envelope(2, payload: payload("office"))

    assert {:ok, _first} = ConfigStore.stage(first, store)
    assert {:ok, second_document} = ConfigStore.stage(second, store)
    assert {:ok, ^second_document} = ConfigStore.stage(second, store)

    assert {:error, %Error{code: :conflict, message: "config version limit reached"}} =
             ConfigStore.stage(envelope(3, payload: payload("lab")), store)

    assert {:ok, ^second_document} = ConfigStore.current(store)
    assert {:ok, entries} = File.ls(Path.join([data_dir, "netman", "versions"]))
    assert length(entries) == 2
  end

  test "fails recovery when persisted versions exceed the configured bound", %{data_dir: data_dir} do
    name = unique_name()
    store = start_store(data_dir, name: name, max_versions: 2)
    assert {:ok, _first} = ConfigStore.stage(envelope(1), store)
    assert {:ok, _second} = ConfigStore.stage(envelope(2, payload: payload("office")), store)
    stop(store)

    assert {:error, {:config_recovery_failed, %Error{code: :invalid}}} =
             ConfigStore.start_link(
               name: name,
               data_dir: data_dir,
               netman_id: @netman_id,
               max_versions: 1
             )
  end

  defp start_store(data_dir, opts \\ []) do
    name = Keyword.get(opts, :name, unique_name())

    store_opts =
      opts
      |> Keyword.delete(:name)
      |> Keyword.merge(name: name, data_dir: data_dir, netman_id: @netman_id)

    {:ok, pid} = ConfigStore.start_link(store_opts)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
    name
  end

  defp stop(name), do: GenServer.stop(name, :normal)
  defp unique_name, do: {:global, {__MODULE__, System.unique_integer([:positive])}}

  defp envelope(version, opts \\ []) do
    payload = Keyword.get(opts, :payload, %{"profiles" => []})
    {:ok, digest} = Digest.calculate(payload)

    %Envelope{
      protocol_version: 1,
      request_id: "00000000-0000-4000-8000-00000000000#{version}",
      target_type: Keyword.get(opts, :target_type, :netman),
      target_id: Keyword.get(opts, :target_id, @netman_id),
      operation: Keyword.get(opts, :operation, "netman.profiles.replace"),
      idempotency_key: "10000000-0000-4000-8000-00000000000#{version}",
      payload: payload,
      payload_digest: Keyword.get(opts, :payload_digest, digest),
      expected_revision: nil,
      config_version: version,
      sent_at: ~U[2026-08-10 00:00:00Z]
    }
  end

  defp payload(profile_id) do
    %{
      "profiles" => [
        %{
          "profile_id" => profile_id,
          "type" => "ethernet",
          "interface" => nil,
          "autoconnect" => true,
          "autoconnect_priority" => 0,
          "zone" => "default",
          "ethernet" => %{"mtu" => nil},
          "ipv4" => %{
            "method" => "auto",
            "address" => nil,
            "gateway" => nil,
            "dns" => [],
            "dns_search" => []
          },
          "ipv6" => %{
            "method" => "auto",
            "address" => nil,
            "gateway" => nil,
            "dns" => [],
            "dns_search" => []
          }
        }
      ]
    }
  end

  defp manifest_path(data_dir), do: Path.join([data_dir, "netman", "manifest.json"])

  defp version_path(data_dir, %{"version" => version, "digest" => digest}) do
    Path.join([data_dir, "netman", "versions", "#{version}-#{digest}.json"])
  end

  defp restore_checkpoint_path(data_dir, delivery) do
    Path.join([
      data_dir,
      "netman",
      "restore-checkpoints",
      "#{delivery.config_version}-#{delivery.payload_digest}.json"
    ])
  end
end
