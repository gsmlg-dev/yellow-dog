defmodule YellowDog.Dhcpv6.PoolStoreFaultFileOps do
  @moduledoc false

  alias YellowDog.Config.TomlHelpers

  @count_key {__MODULE__, :write_count}
  @failure_key {__MODULE__, :failure_write}

  def reset do
    Process.delete(@count_key)
    Process.delete(@failure_key)
  end

  def fail_on_write(write_number) do
    Process.put(@count_key, 0)
    Process.put(@failure_key, write_number)
  end

  def write_count, do: Process.get(@count_key, 0)

  def mkdir_p(path), do: File.mkdir_p(path)

  def atomic_write(path, content) do
    write_number = Process.get(@count_key, 0) + 1
    Process.put(@count_key, write_number)

    if write_number == Process.get(@failure_key) do
      {:error, {:injected_write_failure, write_number}}
    else
      TomlHelpers.atomic_write(path, content)
    end
  end
end

defmodule YellowDog.Dhcpv6.PoolStoreFaultLeaseManager do
  @moduledoc false

  @calls_key {__MODULE__, :calls}
  @pools_key {__MODULE__, :pools}

  def reset(pools \\ []) do
    Process.put(@calls_key, [])
    Process.put(@pools_key, pools)
  end

  def calls, do: Process.get(@calls_key, []) |> Enum.reverse()

  def control_pool_snapshot do
    record(:control_pool_snapshot)
    {:ok, Process.get(@pools_key, [])}
  end

  def control_apply_pool_snapshot(_pools) do
    record(:control_apply_pool_snapshot)
    :ok
  end

  defp record(call), do: Process.put(@calls_key, [call | Process.get(@calls_key, [])])
end

defmodule YellowDog.Dhcpv6.PoolStoreTest do
  use ExUnit.Case, async: false

  alias YellowDog.Dhcpv6.{PoolStore, PoolStoreFaultFileOps, PoolStoreFaultLeaseManager}
  alias YellowDog.Server.Control.Dhcpv6
  alias YellowDog.Sync.Error

  @moduletag :unit

  setup do
    # Create a temporary directory for test files
    tmp_dir = Path.join(System.tmp_dir!(), "pool_store_v6_test_#{:rand.uniform(100_000)}")
    File.mkdir_p!(tmp_dir)

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  describe "save_all_pools/1 and load_pools/1" do
    test "roundtrip saves and loads pools correctly", %{tmp_dir: tmp_dir} do
      index_path = Path.join(tmp_dir, "pools.toml")
      pools_dir = Path.join(tmp_dir, "pools")
      File.mkdir_p!(pools_dir)

      # Mock the data dir by writing directly
      index_content = """
      # DHCPv6 Pool Index
      pools = ["default"]
      """

      pool_content = """
      # DHCPv6 Pool Configuration
      enabled = true
      network = "2001:db8::/64"
      range_start = "2001:db8::100"
      range_end = "2001:db8::200"
      dns_servers = ["2001:4860:4860::8888", "2001:4860:4860::8844"]
      domain_name = "example.local"
      preferred_lifetime = 3600
      valid_lifetime = 7200
      max_leases = 100
      """

      File.write!(index_path, index_content)
      File.write!(Path.join(pools_dir, "default.toml"), pool_content)

      # Load pools back
      assert {:ok, loaded_pools} = PoolStore.load_pools(index_path)
      assert length(loaded_pools) == 1

      loaded = hd(loaded_pools)
      assert loaded.name == "default"
      assert loaded.range_start == "2001:db8::100"
      assert loaded.range_end == "2001:db8::200"
      assert loaded.dns_servers == ["2001:4860:4860::8888", "2001:4860:4860::8844"]
      assert loaded.preferred_lifetime == 3600
      assert loaded.valid_lifetime == 7200
      assert loaded.enabled == true
    end

    test "loads multiple pools from index", %{tmp_dir: tmp_dir} do
      index_path = Path.join(tmp_dir, "pools.toml")
      pools_dir = Path.join(tmp_dir, "pools")
      File.mkdir_p!(pools_dir)

      index_content = """
      # DHCPv6 Pool Index
      pools = ["office", "guest"]
      """

      office_content = """
      enabled = true
      network = "2001:db8:1::/64"
      range_start = "2001:db8:1::100"
      range_end = "2001:db8:1::150"
      """

      guest_content = """
      enabled = true
      network = "2001:db8:2::/64"
      range_start = "2001:db8:2::100"
      range_end = "2001:db8:2::200"
      """

      File.write!(index_path, index_content)
      File.write!(Path.join(pools_dir, "office.toml"), office_content)
      File.write!(Path.join(pools_dir, "guest.toml"), guest_content)

      assert {:ok, loaded_pools} = PoolStore.load_pools(index_path)
      assert length(loaded_pools) == 2

      names = Enum.map(loaded_pools, & &1.name)
      assert "office" in names
      assert "guest" in names
    end

    test "returns empty list when index file doesn't exist", %{tmp_dir: tmp_dir} do
      file_path = Path.join(tmp_dir, "nonexistent.toml")
      assert {:ok, []} = PoolStore.load_pools(file_path)
    end

    test "skips pools in index that don't have corresponding files", %{tmp_dir: tmp_dir} do
      index_path = Path.join(tmp_dir, "pools.toml")
      pools_dir = Path.join(tmp_dir, "pools")
      File.mkdir_p!(pools_dir)

      index_content = """
      pools = ["exists", "missing"]
      """

      exists_content = """
      enabled = true
      network = "fd00::/64"
      range_start = "fd00::1"
      range_end = "fd00::100"
      """

      File.write!(index_path, index_content)
      File.write!(Path.join(pools_dir, "exists.toml"), exists_content)
      # "missing" pool file is intentionally not created

      assert {:ok, loaded_pools} = PoolStore.load_pools(index_path)
      assert length(loaded_pools) == 1
      assert hd(loaded_pools).name == "exists"
    end
  end

  describe "save_pool/1" do
    test "saves a pool file and updates index", %{tmp_dir: tmp_dir} do
      prev = Application.get_env(:yellow_dog, :data_dir)
      Application.put_env(:yellow_dog, :data_dir, tmp_dir)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:yellow_dog, :data_dir, prev),
          else: Application.delete_env(:yellow_dog, :data_dir)
      end)

      pool = %{
        name: "test_v6_pool",
        enabled: true,
        network: "2001:db8::/64",
        range_start: "2001:db8::100",
        range_end: "2001:db8::200",
        dns_servers: ["2001:4860:4860::8888"],
        domain_name: "test.local",
        preferred_lifetime: 3600,
        valid_lifetime: 7200
      }

      assert :ok = PoolStore.save_pool(pool)

      # Verify index was updated
      index_path = Path.join([tmp_dir, "dhcpv6", "pools.toml"])
      assert File.exists?(index_path)
      {:ok, names} = PoolStore.load_index(index_path)
      assert "test_v6_pool" in names

      # Verify pool file was created
      pool_path = Path.join([tmp_dir, "dhcpv6", "pools", "test_v6_pool.toml"])
      assert File.exists?(pool_path)
    end
  end

  describe "remove_pool/1" do
    test "removes a pool file and updates index", %{tmp_dir: tmp_dir} do
      prev = Application.get_env(:yellow_dog, :data_dir)
      Application.put_env(:yellow_dog, :data_dir, tmp_dir)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:yellow_dog, :data_dir, prev),
          else: Application.delete_env(:yellow_dog, :data_dir)
      end)

      pool = %{
        name: "removable_v6",
        enabled: true,
        network: "2001:db8:1::/64",
        range_start: "2001:db8:1::100",
        range_end: "2001:db8:1::200"
      }

      # First save, then remove
      assert :ok = PoolStore.save_pool(pool)
      assert :ok = PoolStore.remove_pool("removable_v6")

      # Verify pool was removed from index
      index_path = Path.join([tmp_dir, "dhcpv6", "pools.toml"])
      {:ok, names} = PoolStore.load_index(index_path)
      refute "removable_v6" in names
    end
  end

  describe "validate_pool/1" do
    test "validates pool with range_start and range_end" do
      pool = %{
        name: "valid",
        network: "2001:db8::/64",
        range_start: "2001:db8::100",
        range_end: "2001:db8::200"
      }

      assert :ok = PoolStore.validate_pool(pool)
    end

    test "validates pool with string keys" do
      pool = %{
        "name" => "valid",
        "network" => "2001:db8::/64",
        "range_start" => "2001:db8::100",
        "range_end" => "2001:db8::200"
      }

      assert :ok = PoolStore.validate_pool(pool)
    end

    test "rejects pool without name" do
      pool = %{
        network: "2001:db8::/64",
        range_start: "2001:db8::100",
        range_end: "2001:db8::200"
      }

      assert {:error, _} = PoolStore.validate_pool(pool)
    end

    test "rejects pool with empty name" do
      pool = %{
        name: "",
        network: "2001:db8::/64",
        range_start: "2001:db8::100",
        range_end: "2001:db8::200"
      }

      assert {:error, _} = PoolStore.validate_pool(pool)
    end

    test "rejects pool without network CIDR" do
      pool = %{
        name: "invalid",
        range_start: "2001:db8::100",
        range_end: "2001:db8::200"
      }

      assert {:error, "Network CIDR is required" <> _} = PoolStore.validate_pool(pool)
    end

    test "rejects pool with invalid network CIDR" do
      pool = %{
        name: "invalid",
        network: "2001:db8::",
        range_start: "2001:db8::100",
        range_end: "2001:db8::200"
      }

      assert {:error, "Invalid network CIDR format" <> _} = PoolStore.validate_pool(pool)
    end

    test "rejects pool without ranges" do
      pool = %{name: "invalid", network: "2001:db8::/64"}
      assert {:error, _} = PoolStore.validate_pool(pool)
    end

    test "rejects pool with invalid IPv6 address" do
      pool = %{
        name: "invalid",
        network: "2001:db8::/64",
        range_start: "not:an:ipv6:address",
        range_end: "2001:db8::200"
      }

      assert {:error, _} = PoolStore.validate_pool(pool)
    end
  end

  describe "default_file_path/0" do
    test "returns a path ending with pools.toml" do
      path = PoolStore.default_file_path()
      assert String.ends_with?(path, "pools.toml")
    end
  end

  describe "control pool facade" do
    test "partial snapshot write keeps the complete prior generation authoritative", %{
      tmp_dir: tmp_dir
    } do
      previous_data_dir = Application.get_env(:yellow_dog, :data_dir)
      previous_pool_store = Application.get_env(:yellow_dog_dhcpv6, PoolStore)
      previous_adapter = Application.get_env(:yellow_dog, Dhcpv6)

      Application.put_env(:yellow_dog, :data_dir, tmp_dir)

      Application.put_env(:yellow_dog_dhcpv6, PoolStore, snapshot_file_ops: PoolStoreFaultFileOps)

      PoolStoreFaultFileOps.reset()
      PoolStoreFaultLeaseManager.reset()

      Application.put_env(:yellow_dog, Dhcpv6,
        pool_store: PoolStore,
        lease_manager: PoolStoreFaultLeaseManager
      )

      on_exit(fn ->
        PoolStoreFaultFileOps.reset()
        PoolStoreFaultLeaseManager.reset()
        restore_env(:yellow_dog, :data_dir, previous_data_dir)
        restore_env(:yellow_dog_dhcpv6, PoolStore, previous_pool_store)
        restore_env(:yellow_dog, Dhcpv6, previous_adapter)
      end)

      old_pool = control_pool("office", "2001:db8:1::", 3600)
      old_guest_pool = control_pool("guest", "2001:db8:2::", 3600)
      old_snapshot = [old_pool, old_guest_pool]
      assert :ok = PoolStore.control_persist_snapshot(old_snapshot)
      PoolStoreFaultLeaseManager.reset(old_snapshot)

      data_dir = Path.join(tmp_dir, "dhcpv6")
      pointer_path = Path.join(data_dir, "pools.current")
      snapshot_root = Path.join(data_dir, "pool_snapshots")
      old_pointer = File.read!(pointer_path)
      old_generation = String.trim(old_pointer)
      old_generation_dir = Path.join(snapshot_root, old_generation)
      old_index_path = Path.join(old_generation_dir, "pools.toml")
      old_pool_path = Path.join([old_generation_dir, "pools", "office.toml"])
      old_index = File.read!(old_index_path)
      old_pool_file = File.read!(old_pool_path)

      PoolStoreFaultFileOps.fail_on_write(2)

      assert {:error, %Error{code: :apply_failed}} =
               Dhcpv6.dispatch("server.dhcp.pools.update", %{
                 "family" => "ipv6",
                 "pool_id" => "office",
                 "subnet" => "2001:db8:1::/64",
                 "start_address" => "2001:db8:1::100",
                 "end_address" => "2001:db8:1::2ff",
                 "lease_seconds" => 3600
               })

      assert PoolStoreFaultFileOps.write_count() == 2
      assert PoolStoreFaultLeaseManager.calls() == [:control_pool_snapshot]
      assert File.read!(pointer_path) == old_pointer
      assert File.read!(old_index_path) == old_index
      assert File.read!(old_pool_path) == old_pool_file
      assert File.ls!(snapshot_root) == [old_generation]

      assert {:ok, persisted_pools} = PoolStore.control_snapshot()
      assert length(persisted_pools) == 2
      persisted_pool = Enum.find(persisted_pools, &(&1.name == "office"))
      assert persisted_pool.name == "office"
      assert persisted_pool.range_end == "2001:db8:1::1ff"

      assert {:error, :unrepresentable_lifetime} =
               PoolStore.control_validate_pool(%{old_pool | valid_lifetime: 7200})
    end

    test "rejects lossless-lifetime gaps and ranges outside the canonical subnet" do
      pool = %{
        name: "control",
        network: "2001:db8::/64",
        range_start: "2001:db8::100",
        range_end: "2001:db8::1ff",
        preferred_lifetime: 3600,
        valid_lifetime: 7200
      }

      assert {:error, :unrepresentable_lifetime} = PoolStore.control_validate_pool(pool)

      assert {:error, :invalid_subnet_range} =
               PoolStore.control_validate_pool(%{
                 pool
                 | valid_lifetime: 3600,
                   range_end: "2001:db9::1"
               })
    end

    test "accepts a canonical IPv6 pool with one lossless lifetime" do
      pool = %{
        name: "control",
        network: "2001:db8::/64",
        range_start: "2001:db8::100",
        range_end: "2001:db8::1ff",
        preferred_lifetime: 3600,
        valid_lifetime: 3600
      }

      assert :ok = PoolStore.control_validate_pool(pool)
    end
  end

  describe "pools_directory/0" do
    test "returns a path ending with pools" do
      path = PoolStore.pools_directory()
      assert String.ends_with?(path, "pools")
    end
  end

  describe "load_index/1" do
    test "loads pool names from index file", %{tmp_dir: tmp_dir} do
      index_path = Path.join(tmp_dir, "pools.toml")

      content = """
      pools = ["pool1", "pool2", "pool3"]
      """

      File.write!(index_path, content)

      assert {:ok, names} = PoolStore.load_index(index_path)
      assert names == ["pool1", "pool2", "pool3"]
    end

    test "returns empty list for missing file", %{tmp_dir: tmp_dir} do
      assert {:ok, []} = PoolStore.load_index(Path.join(tmp_dir, "missing.toml"))
    end

    test "handles [[pool]] format", %{tmp_dir: tmp_dir} do
      index_path = Path.join(tmp_dir, "pools.toml")

      content = """
      [[pool]]
      name = "alpha"

      [[pool]]
      name = "beta"
      """

      File.write!(index_path, content)

      assert {:ok, names} = PoolStore.load_index(index_path)
      assert "alpha" in names
      assert "beta" in names
    end
  end

  defp control_pool(name, prefix, lifetime) do
    %{
      name: name,
      network: "#{prefix}/64",
      range_start: "#{prefix}100",
      range_end: "#{prefix}1ff",
      preferred_lifetime: lifetime,
      valid_lifetime: lifetime
    }
  end

  defp restore_env(application, key, nil), do: Application.delete_env(application, key)
  defp restore_env(application, key, value), do: Application.put_env(application, key, value)
end
