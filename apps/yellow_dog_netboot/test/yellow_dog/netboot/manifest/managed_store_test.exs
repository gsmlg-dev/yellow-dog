defmodule YellowDog.Netboot.Manifest.ManagedStoreTest do
  use ExUnit.Case, async: false

  alias YellowDog.Netboot.Boot.Profile
  alias YellowDog.Netboot.Manifest.ManagedProfile
  alias YellowDog.Netboot.Manifest.ManagedProfileStoreFileOps
  alias YellowDog.Netboot.Manifest.Store

  @table :netboot_profiles

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "netboot_managed_profiles_#{System.unique_integer([:positive])}"
      )

    path = Path.join(root, "managed_profiles.json")
    File.mkdir_p!(root)

    on_exit(fn -> File.rm_rf!(root) end)

    %{path: path}
  end

  test "managed profiles win over configured profiles and delete reveals the fallback", %{
    path: path
  } do
    configure_store(path, configured_profiles())
    managed = managed_profile("nixos")

    assert {:ok, %{previous: empty_snapshot, current: persisted_snapshot}} =
             Store.put_managed_profile(managed)

    assert empty_snapshot == %{"version" => 1, "profiles" => []}

    assert persisted_snapshot == %{
             "version" => 1,
             "profiles" => [ManagedProfile.to_wire(managed)]
           }

    assert {:ok, %Profile{id: "nixos", description: "Configured NixOS"}} =
             Store.get_profile("nixos")

    assert {:ok, ^managed} = Store.get_control_profile("nixos")

    assert Store.list_control_profiles() |> Enum.map(&profile_id/1) |> Enum.sort() == [
             "nixos",
             "rescue"
           ]

    assert {:ok, %{previous: ^persisted_snapshot, current: ^empty_snapshot}} =
             Store.delete_managed_profile("nixos")

    assert {:ok, %Profile{id: "nixos", description: "Configured NixOS"}} =
             Store.get_profile("nixos")

    assert {:ok, %Profile{id: "nixos", description: "Configured NixOS"}} =
             Store.get_control_profile("nixos")
  end

  test "restart loads managed profiles from the explicit sidecar before configured fallback", %{
    path: path
  } do
    configure_store(path, configured_profiles())
    managed = managed_profile("nixos")

    assert {:ok, _snapshots} = Store.put_managed_profile(managed)
    restart_store(path, configured_profiles())

    assert {:ok, %Profile{id: "nixos", description: "Configured NixOS"}} =
             Store.get_profile("nixos")

    assert {:ok, ^managed} = Store.get_control_profile("nixos")
    assert {:ok, %Profile{id: "rescue"}} = Store.get_profile("rescue")
    assert {:ok, snapshot} = Store.managed_snapshot()
    assert snapshot == snapshot([managed])
  end

  test "preserves managed state when a candidate write fails", %{path: path} do
    original = managed_profile("nixos")
    File.write!(path, Jason.encode!(snapshot([original])))
    configure_store(path, %{})

    fail = fn
      :write, _arguments -> {:error, :injected}
      _operation, _arguments -> :pass
    end

    configure_store(path, %{}, file_ops: {ManagedProfileStoreFileOps, %{response: fail}})

    assert {:error, {:persist_failed, :write_failed}} =
             Store.put_managed_profile(managed_profile("rescue"))

    assert {:ok, ^original} = Store.get_control_profile("nixos")
    assert {:error, :not_found} = Store.get_control_profile("rescue")
    assert {:ok, persisted} = path |> File.read!() |> Jason.decode()
    assert persisted == snapshot([original])
  end

  for phase <- [:sync, :rename] do
    test "#{phase} failure leaves managed state and its sidecar unchanged", %{path: path} do
      original = managed_profile("nixos")
      File.write!(path, Jason.encode!(snapshot([original])))
      configure_store(path, %{})

      fail = fn
        unquote(phase), _arguments -> {:error, :injected}
        _operation, _arguments -> :pass
      end

      configure_store(path, %{}, file_ops: {ManagedProfileStoreFileOps, %{response: fail}})

      assert {:error, {:persist_failed, unquote(:"#{phase}_failed")}} =
               Store.put_managed_profile(managed_profile("rescue"))

      assert {:ok, ^original} = Store.get_control_profile("nixos")
      assert {:ok, persisted} = path |> File.read!() |> Jason.decode()
      assert persisted == snapshot([original])
    end
  end

  test "restores the sidecar and visible profiles when activation fails", %{path: path} do
    original = managed_profile("nixos")
    File.write!(path, Jason.encode!(snapshot([original])))
    configure_store(path, %{})

    set_activation(fn profiles ->
      if Map.has_key?(profiles, "rescue"), do: {:error, :injected}, else: :ok
    end)

    assert {:error, {:activation_failed, :callback_error}} =
             Store.put_managed_profile(managed_profile("rescue"))

    assert {:ok, ^original} = Store.get_control_profile("nixos")
    assert {:error, :not_found} = Store.get_control_profile("rescue")
    assert {:error, :not_found} = Store.get_profile("rescue")
    assert {:ok, persisted} = path |> File.read!() |> Jason.decode()
    assert persisted == snapshot([original])
  end

  for {label, failure, expected_reason} <- [
        {"raises", :raise, :callback_exception},
        {"throws", :throw, :callback_throw},
        {"exits", :exit, :callback_exit}
      ] do
    test "activation callback #{label} are sanitized and rolled back", %{path: path} do
      original = managed_profile("nixos")
      File.write!(path, Jason.encode!(snapshot([original])))
      configure_store(path, configured_profiles())
      store_pid = Process.whereis(Store)

      set_activation(fn _profiles -> fail(unquote(failure)) end)

      assert {:error, {:activation_failed, unquote(expected_reason)}} =
               Store.put_managed_profile(managed_profile("rescue"))

      assert Process.whereis(Store) == store_pid
      assert {:ok, ^original} = Store.get_control_profile("nixos")

      assert {:ok, %Profile{id: "rescue", description: "Configured rescue"}} =
               Store.get_control_profile("rescue")

      assert {:ok, %Profile{id: "nixos"}} = Store.get_profile("nixos")
      assert {:ok, persisted} = path |> File.read!() |> Jason.decode()
      assert persisted == snapshot([original])
    end
  end

  for {label, failure, expected_reason} <- [
        {"normal error", :error, :visible_store_error},
        {"exception", :raise, :visible_store_exception},
        {"throw", :throw, :visible_store_throw},
        {"exit", :exit, :visible_store_exit}
      ] do
    test "visible replacement #{label} after mutation restores sidecar and runtime state", %{
      path: path
    } do
      original = managed_profile("nixos")
      File.write!(path, Jason.encode!(snapshot([original])))
      configure_store(path, configured_profiles())
      store_pid = Process.whereis(Store)

      set_visible_replacement(fn _store, _profiles ->
        :ets.delete_all_objects(@table)
        true = :ets.insert(@table, {"corrupt", %Profile{id: "corrupt"}})
        fail(unquote(failure))
      end)

      assert {:error, {:activation_failed, unquote(expected_reason)}} =
               Store.put_managed_profile(managed_profile("rescue"))

      assert Process.whereis(Store) == store_pid
      assert {:ok, ^original} = Store.get_control_profile("nixos")

      assert {:ok, %Profile{id: "rescue", description: "Configured rescue"}} =
               Store.get_control_profile("rescue")

      assert {:error, :not_found} = Store.get_profile("corrupt")

      assert {:ok, %Profile{id: "nixos", description: "Configured NixOS"}} =
               Store.get_profile("nixos")

      assert {:ok, persisted} = path |> File.read!() |> Jason.decode()
      assert persisted == snapshot([original])
    end
  end

  test "reports rollback failure distinctly after an activation failure", %{path: path} do
    original = managed_profile("nixos")
    File.write!(path, Jason.encode!(snapshot([original])))
    configure_store(path, %{})

    counter = :counters.new(1, [])

    fail_rollback = fn
      :rename, _arguments ->
        :counters.add(counter, 1, 1)

        if :counters.get(counter, 1) == 2, do: {:error, :injected}, else: :pass

      _operation, _arguments ->
        :pass
    end

    set_activation(fn _profiles -> {:error, :injected} end)
    set_storage_opts(file_ops: {ManagedProfileStoreFileOps, %{response: fail_rollback}})

    assert {:error, {:rollback_failed, :callback_error, {:sidecar, :rename_failed}}} =
             Store.put_managed_profile(managed_profile("rescue"))

    assert {:ok, ^original} = Store.get_control_profile("nixos")
  end

  test "legacy configured mutations never alter the managed sidecar or default profile", %{
    path: path
  } do
    managed = managed_profile("nixos")
    File.write!(path, Jason.encode!(snapshot([managed])))
    configure_store(path, configured_profiles())

    original_sidecar = File.read!(path)
    assert Store.default_profile_id() == "nixos"

    assert :ok =
             Store.put_profile(%Profile{
               id: "rescue",
               description: "Updated rescue",
               kernel: "rescue/vmlinuz",
               initrd: "rescue/initrd.img",
               arch: [:x86_64]
             })

    assert :ok = Store.delete_profile("rescue")
    assert File.read!(path) == original_sidecar
    assert Store.default_profile_id() == "nixos"

    assert {:ok, %Profile{id: "nixos", description: "Configured NixOS"}} =
             Store.get_profile("nixos")

    assert {:ok, ^managed} = Store.get_control_profile("nixos")
  end

  test "rejects malformed and duplicate managed sidecars without replacing visible profiles", %{
    path: path
  } do
    configure_store(path, configured_profiles())
    assert {:ok, %Profile{id: "nixos"}} = Store.get_profile("nixos")

    File.write!(path, "{")
    assert {:error, {:managed_sidecar_invalid, :invalid_json}} = Store.reload()
    assert {:ok, %Profile{id: "nixos"}} = Store.get_profile("nixos")

    duplicated = snapshot([managed_profile("nixos"), managed_profile("nixos")])
    File.write!(path, Jason.encode!(duplicated))

    assert {:error, {:managed_sidecar_invalid, :duplicate_profile_id}} = Store.reload()
    assert {:ok, %Profile{id: "nixos"}} = Store.get_profile("nixos")
  end

  test "rejects an oversized managed sidecar without replacing visible profiles", %{path: path} do
    configure_store(path, configured_profiles())
    File.write!(path, Jason.encode!(snapshot([managed_profile("nixos")])))
    set_storage_opts(max_bytes: 2)

    assert {:error, {:managed_sidecar_invalid, :too_large}} = Store.reload()
    assert {:ok, %Profile{id: "nixos"}} = Store.get_profile("nixos")
  end

  test "public put rejects an oversized candidate before persistence or activation", %{path: path} do
    original = managed_profile("nixos")
    File.write!(path, Jason.encode!(snapshot([original])))
    configure_store(path, configured_profiles())
    original_sidecar = File.read!(path)

    set_storage_opts(max_bytes: byte_size(original_sidecar))
    oversized = managed_profile("oversized", String.duplicate("x", byte_size(original_sidecar)))

    assert {:error, {:persist_failed, :too_large}} = Store.put_managed_profile(oversized)
    assert File.read!(path) == original_sidecar
    assert {:error, :not_found} = Store.get_control_profile("oversized")
    assert {:error, :not_found} = Store.get_profile("oversized")
    assert {:ok, ^original} = Store.get_control_profile("nixos")
  end

  defp configure_store(path, config, opts \\ []) do
    :ets.delete_all_objects(@table)
    :persistent_term.put({Store, :default_profile}, nil)

    :sys.replace_state(Store, fn state ->
      Map.merge(state, %{
        config: config,
        managed_profiles_path: path,
        managed_storage_opts: Keyword.take(opts, [:file_ops, :max_bytes]),
        managed_activation: Keyword.get(opts, :activation, fn _profiles -> :ok end),
        managed_visible_replacement:
          Keyword.get(opts, :visible_replacement, &default_visible_replacement/2)
      })
    end)

    assert :ok = Store.reload()
  end

  defp configured_profiles do
    %{
      "default_profile" => "nixos",
      "profiles" => %{
        "nixos" => %{
          "description" => "Configured NixOS",
          "kernel" => "nixos/bzImage",
          "initrd" => "nixos/initrd.img",
          "arch" => ["x86_64"]
        },
        "rescue" => %{
          "description" => "Configured rescue",
          "kernel" => "rescue/vmlinuz",
          "initrd" => "rescue/initrd.img",
          "arch" => ["x86_64"]
        }
      }
    }
  end

  defp set_activation(activation) do
    :sys.replace_state(Store, fn state -> Map.put(state, :managed_activation, activation) end)
  end

  defp set_visible_replacement(replacement) do
    :sys.replace_state(Store, fn state ->
      Map.put(state, :managed_visible_replacement, replacement)
    end)
  end

  defp set_storage_opts(opts) do
    :sys.replace_state(Store, fn state ->
      Map.put(state, :managed_storage_opts, Keyword.take(opts, [:file_ops, :max_bytes]))
    end)
  end

  defp restart_store(path, config) do
    assert :ok = Supervisor.terminate_child(YellowDog.Netboot.Supervisor, Store)

    on_exit(fn ->
      if Process.whereis(Store), do: GenServer.stop(Store)
      assert {:ok, _pid} = Supervisor.restart_child(YellowDog.Netboot.Supervisor, Store)
    end)

    assert {:ok, _pid} =
             Store.start_link(
               config: config,
               managed_profiles_path: path
             )
  end

  defp managed_profile(id, name \\ nil) do
    {:ok, profile} =
      ManagedProfile.from_wire(%{
        "profile_id" => id,
        "name" => name || "#{id} managed",
        "boot_asset_id" => "#{id}-ipxe",
        "arguments" => ["ip=dhcp", "console=ttyS0"]
      })

    profile
  end

  defp snapshot(profiles) do
    %{"version" => 1, "profiles" => Enum.map(profiles, &ManagedProfile.to_wire/1)}
  end

  defp profile_id(%{profile_id: id}), do: id
  defp profile_id(%Profile{id: id}), do: id

  defp fail(:error), do: {:error, {:sensitive, String.duplicate("secret", 100)}}
  defp fail(:raise), do: raise("sensitive activation detail")
  defp fail(:throw), do: throw({:sensitive, String.duplicate("secret", 100)})
  defp fail(:exit), do: exit({:sensitive, String.duplicate("secret", 100)})

  defp default_visible_replacement(store, profiles) do
    YellowDog.Data.Store.clear(store)
    |> case do
      {:ok, store} ->
        Enum.reduce_while(profiles, {:ok, store}, fn {id, profile}, {:ok, store} ->
          case YellowDog.Data.Store.put(store, id, profile) do
            {:ok, store} -> {:cont, {:ok, store}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)

      error ->
        error
    end
  end
end
