defmodule YellowDog.Server.Control.NetbootTest do
  use ExUnit.Case, async: false

  alias YellowDog.Server.Control.Dispatcher
  alias YellowDog.Server.Control.Netboot
  alias YellowDog.Server.Control.Revision
  alias YellowDog.ServerNetbootControlFake
  alias YellowDog.Sync.Bounds
  alias YellowDog.Sync.Digest
  alias YellowDog.Sync.Envelope
  alias YellowDog.Sync.Error
  alias YellowDog.Sync.Operation
  alias YellowDog.Sync.ServerOperation

  @request_id "00000000-0000-0000-0000-00000000006d"
  @idempotency_key "00000000-0000-0000-0000-00000000006e"
  @sent_at ~U[2026-07-17 00:00:00Z]
  @observed_at "2026-07-17T00:00:00Z"

  setup do
    previous_netboot = Application.get_env(:yellow_dog, Netboot)
    previous_dispatcher = Application.get_env(:yellow_dog, Dispatcher)

    Application.put_env(:yellow_dog, Netboot,
      manifest_store: YellowDog.ServerNetbootControlFake.ManifestStore,
      managed_profile: YellowDog.ServerNetbootControlFake.ManagedProfile,
      device_registry: YellowDog.ServerNetbootControlFake.DeviceRegistry,
      asset_store: YellowDog.ServerNetbootControlFake.AssetStore,
      file_index: YellowDog.ServerNetbootControlFake.FileIndex,
      clock: YellowDog.ServerNetbootControlFake.Clock
    )

    Application.put_env(:yellow_dog, Dispatcher,
      adapters: %{netboot: Netboot},
      service_registry: YellowDog.ServerControlFake.ServiceRegistry,
      profile_resolver: YellowDog.ServerControlFake.ProfileResolver
    )

    start_supervised!(ServerNetbootControlFake)
    start_supervised!(YellowDog.ServerControlFake)

    on_exit(fn ->
      restore_env(Netboot, previous_netboot)
      restore_env(Dispatcher, previous_dispatcher)
    end)

    :ok
  end

  test "lists canonical managed profiles with complete-list revision before pagination" do
    profiles =
      for index <- 1..(Bounds.max_list_entries() + 2) do
        profile("profile-#{String.pad_leading(Integer.to_string(index), 4, "0")}")
      end
      |> Enum.reverse()

    ServerNetbootControlFake.configure(%{managed_snapshot: managed_snapshot(profiles)})

    assert {:ok, first} =
             Netboot.dispatch("server.netboot.profiles.list", %{
               "cursor" => "profile-0001",
               "limit" => 1
             })

    assert first["items"] == [profile("profile-0002")]
    assert first["observed_at"] == @observed_at

    bounded = profiles |> Enum.sort_by(& &1["profile_id"]) |> Enum.take(1_000)
    assert {:ok, revision} = Revision.calculate(bounded)
    assert first["revision"] == revision

    assert {:ok, second} =
             Netboot.dispatch("server.netboot.profiles.list", %{"limit" => 2})

    assert second["revision"] == revision
    assert_valid_result("server.netboot.profiles.list", first)
  end

  test "lists only UUID-bearing devices and exact ledger-owned assets deterministically" do
    devices = [
      %{uuid: "device-b", profile_id: "rescue", mac: "AA:BB:CC:DD:EE:02", hidden: "/private"},
      %{uuid: nil, profile_id: "legacy", mac: "AA:BB:CC:DD:EE:03"},
      %{uuid: "device-a", profile_id: "default", mac: "AA:BB:CC:DD:EE:01"}
    ]

    assets = [
      asset("asset-b", "b.img", 20),
      asset("asset-a", "a.img", 10)
    ]

    ServerNetbootControlFake.configure(%{
      device_snapshot: {:ok, devices},
      asset_snapshot: {:ok, assets}
    })

    assert {:ok, device_result} =
             Netboot.dispatch("server.netboot.devices.list", %{"limit" => 1})

    assert device_result["items"] == [
             %{
               "device_id" => "device-a",
               "profile_id" => "default",
               "mac" => "AA:BB:CC:DD:EE:01"
             }
           ]

    assert {:ok, asset_result} =
             Netboot.dispatch("server.netboot.assets.list", %{"cursor" => "asset-a"})

    assert asset_result["items"] == [asset("asset-b", "b.img", 20)]
    assert_valid_result("server.netboot.devices.list", device_result)
    assert_valid_result("server.netboot.assets.list", asset_result)
    refute inspect(device_result) =~ "/private"
  end

  test "puts and deletes profiles using exact canonical managed snapshots" do
    prior = profile("installer")
    updated = %{prior | "name" => "Installer v2"}
    prior_snapshot = managed_snapshot([prior])
    current_snapshot = managed_snapshot([updated])

    ServerNetbootControlFake.configure(%{
      managed_snapshot: prior_snapshot,
      profile_put:
        {:ok, %{previous: snapshot_document([prior]), current: snapshot_document([updated])}},
      profile_delete:
        {:ok, %{previous: snapshot_document([updated]), current: snapshot_document([])}}
    })

    assert {:ok, current} = Netboot.current("server.netboot.profiles.put", updated)
    assert current == prior

    assert {:ok, put_result} = Netboot.dispatch("server.netboot.profiles.put", updated)
    assert put_result["resource"] == updated
    assert put_result["resource_type"] == "netboot_profile"
    assert {:ok, put_revision} = Revision.calculate(updated)
    assert put_result["revision"] == put_revision

    ServerNetbootControlFake.configure(%{managed_snapshot: current_snapshot})
    ref = %{"profile_id" => "installer"}
    assert {:ok, ^updated} = Netboot.current("server.netboot.profiles.delete", ref)
    assert {:ok, deleted} = Netboot.dispatch("server.netboot.profiles.delete", ref)
    assert deleted["resource_ref"] == ref
    assert {:ok, delete_revision} = Revision.calculate(ref)
    assert deleted["revision"] == delete_revision
    assert_valid_result("server.netboot.profiles.put", put_result)
    assert_valid_result("server.netboot.profiles.delete", deleted)
  end

  test "never coerces configured profile fallbacks into the managed wire contract" do
    configured_fallback = %{
      id: "legacy",
      description: "Legacy",
      kernel: "vmlinuz",
      initrd: "initrd.img",
      kernel_args: "console=ttyS0"
    }

    ServerNetbootControlFake.configure(%{
      managed_snapshot: {:ok, %{"version" => 1, "profiles" => [configured_fallback]}}
    })

    assert_error(:apply_failed, Netboot.dispatch("server.netboot.profiles.list", %{}))

    assert_error(
      :apply_failed,
      Netboot.current("server.netboot.profiles.delete", %{"profile_id" => "legacy"})
    )
  end

  test "creates updates re-keys and deletes devices from owner snapshots" do
    original = device("device-1", "default", "AA:BB:CC:DD:EE:01", state: :installed)
    rekeyed = %{original | mac: "AA:BB:CC:DD:EE:02", profile_id: "rescue"}

    ServerNetbootControlFake.configure(%{
      device_snapshot: {:ok, []},
      device_put: {:ok, [], [original]}
    })

    payload = public_device(original)
    assert {:ok, :missing} = Netboot.current("server.netboot.devices.put", payload)
    assert {:ok, created} = Netboot.dispatch("server.netboot.devices.put", payload)
    assert created["resource"] == payload

    ServerNetbootControlFake.configure(%{
      device_snapshot: {:ok, [original]},
      device_put: {:ok, [original], [rekeyed]},
      device_delete: {:ok, [rekeyed], []}
    })

    update_payload = public_device(rekeyed)
    assert {:ok, ^payload} = Netboot.current("server.netboot.devices.put", update_payload)
    assert {:ok, updated} = Netboot.dispatch("server.netboot.devices.put", update_payload)
    assert updated["resource"] == update_payload

    ServerNetbootControlFake.configure(%{device_snapshot: {:ok, [rekeyed]}})
    ref = %{"device_id" => "device-1"}
    assert {:ok, ^update_payload} = Netboot.current("server.netboot.devices.delete", ref)
    assert {:ok, deleted} = Netboot.dispatch("server.netboot.devices.delete", ref)
    assert deleted["resource_ref"] == ref
    assert_valid_result("server.netboot.devices.put", updated)
    assert_valid_result("server.netboot.devices.delete", deleted)
  end

  test "real Dispatcher is the sole stale-revision gate for profile and device mutations" do
    profile = profile("installer")
    device = device("device-1", "default", "AA:BB:CC:DD:EE:01")

    ServerNetbootControlFake.configure(%{
      managed_snapshot: managed_snapshot([profile]),
      device_snapshot: {:ok, [device]},
      profile_put: {:raise, "must not mutate stale profile"},
      device_delete: {:raise, "must not mutate stale device"}
    })

    stale = String.duplicate("a", 64)

    assert_error(
      :conflict,
      Dispatcher.dispatch(
        envelope("server.netboot.profiles.put", %{profile | "name" => "Changed"},
          expected_revision: stale
        )
      )
    )

    assert_error(
      :conflict,
      Dispatcher.dispatch(
        envelope(
          "server.netboot.devices.delete",
          %{"device_id" => "device-1"},
          expected_revision: stale
        )
      )
    )

    refute Enum.any?(ServerNetbootControlFake.take_calls(), fn
             {:manifest_store, :put_managed_profile, _} -> true
             {:device_registry, :control_delete_device, _} -> true
             _call -> false
           end)
  end

  test "rescans both scopes after revisioning the safe pre-scan index projection" do
    index = [
      {"z.img", "/srv/netboot/z.img", 20},
      {"a.img", "/srv/netboot/a.img", 10}
    ]

    ServerNetbootControlFake.configure(%{
      file_index_snapshot: index,
      asset_rescan: {:ok, 2}
    })

    safe_index = [
      %{"filename" => "a.img", "size" => 10},
      %{"filename" => "z.img", "size" => 20}
    ]

    assert {:ok, ^safe_index} =
             Netboot.current("server.netboot.assets.rescan", %{"scope" => "all"})

    assert {:ok, revision} = Revision.calculate(safe_index)

    for scope <- ["all", "missing"] do
      assert {:ok, %{"scope" => ^scope, "discovered_assets" => 2} = result} =
               Dispatcher.dispatch(
                 envelope(
                   "server.netboot.assets.rescan",
                   %{"scope" => scope},
                   expected_revision: revision
                 )
               )

      assert_valid_result("server.netboot.assets.rescan", result)
    end

    calls = ServerNetbootControlFake.take_calls()
    assert Enum.count(calls, &match?({:file_index, :snapshot, []}, &1)) == 3
    assert Enum.count(calls, &match?({:asset_store, :control_rescan, [_]}, &1)) == 2
    refute Enum.any?(calls, &match?({:asset_store, :control_snapshot, []}, &1))
    refute inspect(safe_index) =~ "/srv/netboot"
  end

  test "unsupported operations validate first and never read or mutate owners" do
    cases = [
      {"server.netboot.assets.upload", asset("asset-a", "a.img", 10)},
      {"server.netboot.assets.delete", %{"asset_id" => "asset-a"}},
      {"server.netboot.transfers.list", %{}},
      {"server.netboot.logs.list", %{}}
    ]

    for {operation, payload} <- cases do
      assert_error(:unsupported, Netboot.dispatch(operation, payload))

      if String.contains?(operation, ".assets.") and
           not String.ends_with?(operation, ".list") do
        assert_error(:unsupported, Netboot.current(operation, payload))
      end
    end

    assert [] = ServerNetbootControlFake.take_calls()

    assert_error(
      :invalid,
      Netboot.dispatch("server.netboot.assets.upload", %{"asset_id" => "bad"})
    )

    assert_error(:invalid, Netboot.dispatch("server.netboot.logs.list", %{"limit" => 0}))
    assert [] = ServerNetbootControlFake.take_calls()
  end

  test "maps owner errors malformed replies and failures to sanitized Sync errors" do
    mappings = [
      {:not_found, {:error, :not_found}},
      {:conflict, {:error, :conflict}},
      {:invalid, {:error, :invalid_snapshot}},
      {:apply_failed, {:error, :persistence_failed}},
      {:rollback_failed, {:error, :rollback_failed}},
      {:apply_failed, :malformed},
      {:apply_failed, {:raise, "owner secret /var/lib/yellowdog"}},
      {:apply_failed, {:throw, "owner secret"}},
      {:apply_failed, {:exit, :owner_failed}}
    ]

    for {code, response} <- mappings do
      ServerNetbootControlFake.configure(%{device_snapshot: response})
      result = Netboot.dispatch("server.netboot.devices.list", %{})
      assert_error(code, result)
      refute inspect(result) =~ "/var/lib/yellowdog"
    end

    ServerNetbootControlFake.configure(%{managed_snapshot: {:exit, :noproc}})
    assert_error(:not_found, Netboot.dispatch("server.netboot.profiles.list", %{}))
  end

  test "rejects invalid dependency overrides without invoking caller-selected modules" do
    Application.put_env(:yellow_dog, Netboot,
      manifest_store: System,
      unexpected_owner: System
    )

    assert_error(:apply_failed, Netboot.dispatch("server.netboot.profiles.list", %{}))
    assert [] = ServerNetbootControlFake.take_calls()
  end

  test "Dispatcher disabled and unavailable gates make zero owner packet or socket calls" do
    YellowDog.ServerControlFake.set_available(:netboot, false)

    assert_error(
      :unsupported,
      Dispatcher.dispatch(envelope("server.netboot.assets.list", %{}))
    )

    assert [] = ServerNetbootControlFake.take_calls()

    YellowDog.ServerControlFake.set_available(:netboot, true)
    YellowDog.ServerControlFake.set_enabled(:netboot, false)

    assert_error(
      :unsupported,
      Dispatcher.dispatch(envelope("server.netboot.devices.list", %{}))
    )

    assert [] = ServerNetbootControlFake.take_calls()
    assert [] = ServerNetbootControlFake.packet_or_socket_calls()
  end

  defp profile(id) do
    %{
      "profile_id" => id,
      "name" => "Profile #{id}",
      "boot_asset_id" => "asset-#{id}",
      "arguments" => ["console=ttyS0", "quiet"]
    }
  end

  defp managed_snapshot(profiles), do: {:ok, snapshot_document(profiles)}

  defp snapshot_document(profiles), do: %{"version" => 1, "profiles" => profiles}

  defp device(id, profile_id, mac, overrides \\ []) do
    %{
      uuid: id,
      profile_id: profile_id,
      mac: mac,
      state: Keyword.get(overrides, :state, :discovered),
      hidden_runtime: %{path: "/ignored"}
    }
  end

  defp public_device(device) do
    %{
      "device_id" => device.uuid,
      "profile_id" => device.profile_id,
      "mac" => device.mac
    }
  end

  defp asset(id, filename, size) do
    %{
      "asset_id" => id,
      "filename" => filename,
      "size" => size,
      "blob_digest" => String.duplicate("a", 64)
    }
  end

  defp envelope(operation, payload, overrides \\ []) do
    {:ok, payload_digest} = Digest.calculate(payload)

    %Envelope{
      protocol_version: 1,
      request_id: @request_id,
      target_type: :server,
      target_id: "server-task-6d",
      operation: operation,
      idempotency_key: @idempotency_key,
      payload: payload,
      payload_digest: payload_digest,
      expected_revision: Keyword.get(overrides, :expected_revision),
      config_version: nil,
      sent_at: @sent_at
    }
  end

  defp assert_valid_result(operation_name, result) do
    assert {:ok, operation} = ServerOperation.fetch(operation_name)
    assert {:ok, ^result} = Operation.validate_result(operation, result)
  end

  defp assert_error(code, {:error, %Error{code: code, details: %{}}}), do: :ok
  defp assert_error(code, other), do: flunk("expected #{code}, got: #{inspect(other)}")

  defp restore_env(module, nil), do: Application.delete_env(:yellow_dog, module)
  defp restore_env(module, config), do: Application.put_env(:yellow_dog, module, config)
end
