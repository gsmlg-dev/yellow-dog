defmodule YellowDog.Netman.Control.ConfigRuntimeAdapterTest do
  use ExUnit.Case, async: false

  alias YellowDog.Netman.Control.ConfigRuntimeAdapter
  alias __MODULE__.ProfilesFake
  alias __MODULE__.ResolvedFake
  alias YellowDog.NetmanAgent.ConfigStore
  alias YellowDog.Sync.Digest
  alias YellowDog.Sync.Envelope

  @moduletag :tmp_dir
  @netman_id "netman-runtime-adapter"
  @namespace_revision String.duplicate("a", 64)
  @resolved_revision String.duplicate("b", 64)

  setup %{tmp_dir: tmp_dir} do
    name = {:global, {__MODULE__, System.unique_integer([:positive])}}
    previous = Application.fetch_env(:yellow_dog_netman, ConfigRuntimeAdapter)

    {:ok, store} =
      ConfigStore.start_link(
        name: name,
        data_dir: Path.expand(tmp_dir),
        netman_id: @netman_id
      )

    ProfilesFake.configure(self(), @namespace_revision, :ok, %{"profiles" => []})
    ResolvedFake.configure(self(), @resolved_revision, :ok, :ok)

    Application.put_env(:yellow_dog_netman, ConfigRuntimeAdapter,
      config_store: name,
      profiles: ProfilesFake,
      resolved: ResolvedFake
    )

    on_exit(fn ->
      if Process.alive?(store), do: GenServer.stop(store)
      ProfilesFake.clear()
      ResolvedFake.clear()
      restore_env(previous)
    end)

    %{data_dir: Path.expand(tmp_dir), store: store, store_name: name}
  end

  test "validates only exact payloads for the three Netman config operations" do
    assert :ok = ConfigRuntimeAdapter.validate_config(payload("office"))

    assert :ok =
             ConfigRuntimeAdapter.validate_config(%{
               "upstreams" => ["192.0.2.53"],
               "search_domains" => ["example.test"]
             })

    assert :ok =
             ConfigRuntimeAdapter.validate_config(%{
               "target_revision" => String.duplicate("c", 64)
             })

    assert {:error, :invalid_config} =
             ConfigRuntimeAdapter.validate_config(%{
               "profiles" => [],
               "management_token" => "must-stay-local"
             })

    assert {:error, :invalid_config} =
             ConfigRuntimeAdapter.validate_config(%{"profiles" => [%{}]})
  end

  test "installs only the exact durable staged delivery", %{store_name: store} do
    delivery = envelope(1, payload("office"))
    revision = delivery.payload_digest
    assert {:ok, _document} = ConfigStore.stage(delivery, store)

    assert {:ok, ^revision} =
             ConfigRuntimeAdapter.install_config(delivery.payload,
               version: delivery.config_version,
               digest: delivery.payload_digest,
               expected_revision: nil,
               operation: "netman.profiles.replace"
             )

    assert {:error, :install_failed} =
             ConfigRuntimeAdapter.install_config(delivery.payload,
               version: delivery.config_version,
               digest: delivery.payload_digest,
               expected_revision: nil,
               operation: "netman.resolved.config.update"
             )

    assert {:error, :install_failed} =
             ConfigRuntimeAdapter.install_config(delivery.payload,
               version: delivery.config_version + 1,
               digest: delivery.payload_digest,
               expected_revision: nil,
               operation: "netman.profiles.replace"
             )

    assert {:ok, checkpoint} =
             ConfigStore.fetch_restore_checkpoint(delivery.payload_digest, store)

    assert checkpoint["restore_operation"] == "netman.profiles.replace"
    assert checkpoint["restore_payload"] == %{"profiles" => []}
  end

  test "activates and restores exact durable revisions after ConfigStore restarts", %{
    data_dir: data_dir,
    store: store,
    store_name: store_name
  } do
    first = envelope(1, payload("office"))
    second = envelope(2, payload("lab"), first.payload_digest)
    first_payload = first.payload
    second_payload = second.payload

    assert {:ok, _first_document} = ConfigStore.stage(first, store_name)
    assert {:ok, _second_document} = ConfigStore.stage(second, store_name)

    GenServer.stop(store)

    assert {:ok, restarted} =
             ConfigStore.start_link(
               name: store_name,
               data_dir: data_dir,
               netman_id: @netman_id
             )

    assert :ok = ConfigRuntimeAdapter.activate_config(second.payload_digest)

    assert_receive {:profiles_current, "netman.profiles.replace", ^second_payload}

    assert_receive {:profiles_dispatch, "netman.profiles.replace", ^second_payload,
                    %{
                      config_version: 2,
                      current_revision: @namespace_revision,
                      expected_revision: @namespace_revision,
                      precondition: {:revision, @namespace_revision}
                    }}

    assert :ok = ConfigRuntimeAdapter.activate_config(first.payload_digest)

    assert_receive {:profiles_current, "netman.profiles.replace", ^first_payload}

    assert_receive {:profiles_dispatch, "netman.profiles.replace", ^first_payload,
                    %{config_version: 1}}

    assert Process.alive?(restarted)
  end

  test "installs and activates an exact durable Resolved rollback", %{store_name: store} do
    payload = %{"target_revision" => String.duplicate("c", 64)}

    delivery =
      envelope(1, payload, nil, operation: "netman.resolved.config.rollback")

    install(delivery, store)

    assert {:ok, checkpoint} =
             ConfigStore.fetch_restore_checkpoint(delivery.payload_digest, store)

    assert checkpoint["restore_operation"] == "netman.resolved.config.rollback"
    assert checkpoint["restore_payload"] == %{"target_revision" => @resolved_revision}

    assert :ok = ConfigRuntimeAdapter.activate_config(delivery.payload_digest)

    assert_receive {:resolved_apply, "netman.resolved.config.rollback", ^payload}
  end

  test "failed Resolved activation restores Resolved after a profile version", %{
    store_name: store
  } do
    profile_delivery = envelope(1, payload("office"))
    resolved_payload = %{"upstreams" => ["192.0.2.53"], "search_domains" => ["example.test"]}

    resolved_delivery =
      envelope(2, resolved_payload, profile_delivery.payload_digest,
        operation: "netman.resolved.config.update"
      )

    install(profile_delivery, store)
    assert :ok = ConfigRuntimeAdapter.activate_config(profile_delivery.payload_digest)
    assert_receive {:profiles_dispatch, "netman.profiles.replace", _, _}

    install(resolved_delivery, store)
    ResolvedFake.configure(self(), @resolved_revision, {:error, :apply_failed}, :ok)

    assert {:error, :activation_failed} =
             ConfigRuntimeAdapter.activate_config(resolved_delivery.payload_digest)

    assert_receive {:resolved_apply, "netman.resolved.config.update", ^resolved_payload}

    ResolvedFake.configure(self(), @resolved_revision, :ok, :ok)

    assert :ok =
             ConfigRuntimeAdapter.restore_config({:candidate, resolved_delivery.payload_digest})

    assert_receive {:resolved_restore, @resolved_revision}

    assert :ok = ConfigRuntimeAdapter.activate_config(profile_delivery.payload_digest)
    assert_receive {:profiles_dispatch, "netman.profiles.replace", _, _}
    refute_receive {:profiles_dispatch, "netman.resolved.config.update", _, _}
  end

  test "failed profile activation restores profiles after a Resolved version", %{
    store_name: store
  } do
    resolved_payload = %{"upstreams" => ["192.0.2.53"], "search_domains" => ["example.test"]}

    resolved_delivery =
      envelope(1, resolved_payload, nil, operation: "netman.resolved.config.update")

    profile_delivery = envelope(2, payload("office"), resolved_delivery.payload_digest)

    install(resolved_delivery, store)
    assert :ok = ConfigRuntimeAdapter.activate_config(resolved_delivery.payload_digest)
    assert_receive {:resolved_apply, "netman.resolved.config.update", ^resolved_payload}

    install(profile_delivery, store)

    ProfilesFake.configure(self(), @namespace_revision, {:error, :apply_failed}, %{
      "profiles" => []
    })

    assert {:error, :activation_failed} =
             ConfigRuntimeAdapter.activate_config(profile_delivery.payload_digest)

    assert_receive {:profiles_dispatch, "netman.profiles.replace", _, _}

    ProfilesFake.configure(self(), @namespace_revision, :ok, %{"profiles" => []})

    assert :ok =
             ConfigRuntimeAdapter.restore_config({:candidate, profile_delivery.payload_digest})

    assert_receive {:profiles_dispatch, "netman.profiles.replace", %{"profiles" => []}, _}

    assert :ok = ConfigRuntimeAdapter.activate_config(resolved_delivery.payload_digest)
    assert_receive {:resolved_apply, "netman.resolved.config.update", ^resolved_payload}
  end

  test "fails closed for unavailable revisions and runtime application failures", %{
    store_name: store
  } do
    assert {:error, :activation_failed} =
             ConfigRuntimeAdapter.activate_config(String.duplicate("f", 64))

    delivery = envelope(1, payload("office"))
    assert {:ok, _document} = ConfigStore.stage(delivery, store)

    ProfilesFake.configure(self(), @namespace_revision, {:error, :apply_failed}, %{
      "profiles" => []
    })

    assert {:error, :activation_failed} =
             ConfigRuntimeAdapter.activate_config(delivery.payload_digest)

    assert {:error, :restore_failed} =
             ConfigRuntimeAdapter.restore_config(delivery.payload_digest)
  end

  defp envelope(version, payload, expected_revision \\ nil) do
    envelope(version, payload, expected_revision, [])
  end

  defp envelope(version, payload, expected_revision, opts) do
    {:ok, digest} = Digest.calculate(payload)

    %Envelope{
      protocol_version: 1,
      request_id:
        "00000000-0000-4000-8000-#{String.pad_leading(Integer.to_string(version), 12, "0")}",
      target_type: :netman,
      target_id: @netman_id,
      operation: Keyword.get(opts, :operation, "netman.profiles.replace"),
      idempotency_key:
        "10000000-0000-4000-8000-#{String.pad_leading(Integer.to_string(version), 12, "0")}",
      payload: payload,
      payload_digest: digest,
      expected_revision: expected_revision,
      config_version: version,
      sent_at: ~U[2026-08-11 00:00:00Z]
    }
  end

  defp install(delivery, store) do
    assert {:ok, _document} = ConfigStore.stage(delivery, store)

    assert {:ok, revision} =
             ConfigRuntimeAdapter.install_config(delivery.payload,
               version: delivery.config_version,
               digest: delivery.payload_digest,
               expected_revision: delivery.expected_revision,
               operation: delivery.operation
             )

    assert revision == delivery.payload_digest
  end

  defp payload(profile_id) do
    %{
      "profiles" => [
        %{
          "profile_id" => profile_id,
          "type" => "ethernet",
          "interface" => nil,
          "autoconnect" => false,
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
            "method" => "disabled",
            "address" => nil,
            "gateway" => nil,
            "dns" => [],
            "dns_search" => []
          }
        }
      ]
    }
  end

  defp restore_env({:ok, value}),
    do: Application.put_env(:yellow_dog_netman, ConfigRuntimeAdapter, value)

  defp restore_env(:error), do: Application.delete_env(:yellow_dog_netman, ConfigRuntimeAdapter)

  defmodule ProfilesFake do
    @key {__MODULE__, :state}

    def configure(owner, current_revision, dispatch_result, snapshot_payload) do
      :persistent_term.put(@key, %{
        owner: owner,
        current_revision: current_revision,
        dispatch_result: dispatch_result,
        snapshot_payload: snapshot_payload
      })
    end

    def clear, do: :persistent_term.erase(@key)

    def current(operation, payload) do
      state = :persistent_term.get(@key)
      send(state.owner, {:profiles_current, operation, payload})
      {:ok, state.current_revision}
    end

    def replacement_snapshot do
      state = :persistent_term.get(@key)
      send(state.owner, {:profiles_snapshot, state.snapshot_payload, state.current_revision})
      {:ok, state.snapshot_payload, state.current_revision}
    end

    def dispatch(operation, payload, context) do
      state = :persistent_term.get(@key)
      send(state.owner, {:profiles_dispatch, operation, payload, context})

      case state.dispatch_result do
        :ok ->
          {:ok,
           %{
             "state" => "applied",
             "applied_revision" => state.current_revision
           }}

        error ->
          error
      end
    end
  end

  defmodule ResolvedFake do
    @key {__MODULE__, :state}

    def configure(owner, current_revision, apply_result, restore_result) do
      :persistent_term.put(@key, %{
        owner: owner,
        current_revision: current_revision,
        apply_result: apply_result,
        restore_result: restore_result
      })
    end

    def clear, do: :persistent_term.erase(@key)

    def current(operation, payload) do
      state = :persistent_term.get(@key)
      send(state.owner, {:resolved_current, operation, payload})
      {:ok, state.current_revision}
    end

    def apply_config(operation, payload) do
      state = :persistent_term.get(@key)
      send(state.owner, {:resolved_apply, operation, payload})
      state.apply_result
    end

    def restore_config(revision) do
      state = :persistent_term.get(@key)
      send(state.owner, {:resolved_restore, revision})
      state.restore_result
    end
  end
end
