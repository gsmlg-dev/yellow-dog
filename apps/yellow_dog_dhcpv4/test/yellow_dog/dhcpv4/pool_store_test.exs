defmodule YellowDog.Dhcpv4.PoolStoreTest do
  use ExUnit.Case, async: false

  alias YellowDog.Dhcpv4.PoolStore

  @moduletag :unit

  setup do
    # Create a temporary directory for test files
    tmp_dir = Path.join(System.tmp_dir!(), "pool_store_test_#{:rand.uniform(100_000)}")
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
      # DHCPv4 Pool Index
      pools = ["default"]
      """

      pool_content = """
      # DHCPv4 Pool Configuration
      enabled = true
      network = "192.168.1.0/24"
      range_start = "192.168.1.100"
      range_end = "192.168.1.200"
      subnet_mask = "255.255.255.0"
      gateway = "192.168.1.1"
      dns_servers = ["8.8.8.8", "8.8.4.4"]
      domain_name = "example.local"
      lease_time = 86400
      max_leases = 100
      """

      File.write!(index_path, index_content)
      File.write!(Path.join(pools_dir, "default.toml"), pool_content)

      # Load pools back
      assert {:ok, loaded_pools} = PoolStore.load_pools(index_path)
      assert length(loaded_pools) == 1

      loaded = hd(loaded_pools)
      assert loaded.name == "default"
      assert loaded.range_start == "192.168.1.100"
      assert loaded.range_end == "192.168.1.200"
      assert loaded.gateway == "192.168.1.1"
      assert loaded.dns_servers == ["8.8.8.8", "8.8.4.4"]
      assert loaded.lease_time == 86400
      assert loaded.enabled == true
    end

    test "loads multiple pools from index", %{tmp_dir: tmp_dir} do
      index_path = Path.join(tmp_dir, "pools.toml")
      pools_dir = Path.join(tmp_dir, "pools")
      File.mkdir_p!(pools_dir)

      index_content = """
      # DHCPv4 Pool Index
      pools = ["office", "guest"]
      """

      office_content = """
      enabled = true
      network = "192.168.1.0/24"
      range_start = "192.168.1.100"
      range_end = "192.168.1.150"
      """

      guest_content = """
      enabled = true
      network = "192.168.2.0/24"
      range_start = "192.168.2.100"
      range_end = "192.168.2.200"
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
      network = "10.0.0.0/24"
      range_start = "10.0.0.1"
      range_end = "10.0.0.100"
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
        name: "test_v4_pool",
        enabled: true,
        network: "192.168.50.0/24",
        range_start: "192.168.50.100",
        range_end: "192.168.50.200",
        subnet_mask: "255.255.255.0",
        gateway: "192.168.50.1",
        dns_servers: ["8.8.8.8"],
        domain_name: "test.local",
        lease_time: 3600
      }

      assert :ok = PoolStore.save_pool(pool)

      # Verify index was updated
      index_path = Path.join([tmp_dir, "dhcpv4", "pools.toml"])
      assert File.exists?(index_path)
      {:ok, names} = PoolStore.load_index(index_path)
      assert "test_v4_pool" in names

      # Verify pool file was created
      pool_path = Path.join([tmp_dir, "dhcpv4", "pools", "test_v4_pool.toml"])
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
        name: "removable_v4",
        enabled: true,
        network: "192.168.60.0/24",
        range_start: "192.168.60.100",
        range_end: "192.168.60.200"
      }

      # First save, then remove
      assert :ok = PoolStore.save_pool(pool)
      assert :ok = PoolStore.remove_pool("removable_v4")

      # Verify pool was removed from index
      index_path = Path.join([tmp_dir, "dhcpv4", "pools.toml"])
      {:ok, names} = PoolStore.load_index(index_path)
      refute "removable_v4" in names
    end
  end

  describe "validate_pool/1" do
    test "validates pool with range_start and range_end" do
      pool = %{
        name: "valid",
        network: "192.168.1.0/24",
        range_start: "192.168.1.100",
        range_end: "192.168.1.200"
      }

      assert :ok = PoolStore.validate_pool(pool)
    end

    test "validates pool with string keys" do
      pool = %{
        "name" => "valid",
        "network" => "192.168.1.0/24",
        "range_start" => "192.168.1.100",
        "range_end" => "192.168.1.200"
      }

      assert :ok = PoolStore.validate_pool(pool)
    end

    test "rejects pool without name" do
      pool = %{
        network: "192.168.1.0/24",
        range_start: "192.168.1.100",
        range_end: "192.168.1.200"
      }

      assert {:error, _} = PoolStore.validate_pool(pool)
    end

    test "rejects pool with empty name" do
      pool = %{
        name: "",
        network: "192.168.1.0/24",
        range_start: "192.168.1.100",
        range_end: "192.168.1.200"
      }

      assert {:error, _} = PoolStore.validate_pool(pool)
    end

    test "rejects pool without network CIDR" do
      pool = %{
        name: "invalid",
        range_start: "192.168.1.100",
        range_end: "192.168.1.200"
      }

      assert {:error, "Network CIDR is required" <> _} = PoolStore.validate_pool(pool)
    end

    test "rejects pool with invalid network CIDR" do
      pool = %{
        name: "invalid",
        network: "192.168.1.0",
        range_start: "192.168.1.100",
        range_end: "192.168.1.200"
      }

      assert {:error, "Invalid network CIDR format" <> _} = PoolStore.validate_pool(pool)
    end

    test "rejects pool without ranges" do
      pool = %{name: "invalid", network: "192.168.1.0/24"}
      assert {:error, _} = PoolStore.validate_pool(pool)
    end

    test "rejects pool with invalid IP address" do
      pool = %{
        name: "invalid",
        network: "192.168.1.0/24",
        range_start: "not.an.ip.address",
        range_end: "192.168.1.200"
      }

      assert {:error, _} = PoolStore.validate_pool(pool)
    end
  end

  describe "control pool snapshots" do
    test "rejects host-address network CIDRs before persistence", %{tmp_dir: tmp_dir} do
      use_data_dir(tmp_dir)

      pool = %{
        name: "host-cidr",
        network: "192.0.2.7/24",
        range_start: "192.0.2.20",
        range_end: "192.0.2.100",
        subnet_mask: "255.255.255.0",
        lease_time: 3600
      }

      assert {:error, :invalid} = PoolStore.control_validate_pool(pool)
      assert {:error, :invalid} = PoolStore.control_persist_snapshot([pool])
      assert {:ok, []} = PoolStore.control_snapshot()
      refute File.exists?(PoolStore.default_index_path())
    end

    test "validates and roundtrips an explicit durable snapshot", %{tmp_dir: tmp_dir} do
      previous = Application.get_env(:yellow_dog, :data_dir)
      Application.put_env(:yellow_dog, :data_dir, tmp_dir)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:yellow_dog, :data_dir, previous),
          else: Application.delete_env(:yellow_dog, :data_dir)
      end)

      pool = %{
        name: "control-v4",
        network: "192.0.2.0/24",
        range_start: "192.0.2.20",
        range_end: "192.0.2.100",
        subnet_mask: "255.255.255.0",
        lease_time: 3600
      }

      assert :ok = PoolStore.control_validate_pool(pool)
      assert :ok = PoolStore.control_persist_snapshot([pool])
      assert {:ok, [snapshot]} = PoolStore.control_snapshot()
      assert snapshot.name == "control-v4"
      assert snapshot.network == "192.0.2.0/24"
      assert snapshot.range_start == "192.0.2.20"
    end

    test "keeps the prior snapshot authoritative when index commit fails after staging", %{
      tmp_dir: tmp_dir
    } do
      use_data_dir(tmp_dir)

      original = %{
        name: "control-v4",
        network: "192.0.2.0/24",
        range_start: "192.0.2.20",
        range_end: "192.0.2.100",
        subnet_mask: "255.255.255.0",
        lease_time: 3600
      }

      candidate = %{
        original
        | range_start: "192.0.2.40",
          range_end: "192.0.2.120",
          lease_time: 7200
      }

      assert :ok = PoolStore.control_persist_snapshot([original])

      index_path = PoolStore.default_index_path()
      original_index = File.read!(index_path)

      # atomic_write/2 reaches this path only after all candidate pool files are staged.
      File.mkdir_p!(index_path <> ".tmp")

      assert {:error, _reason} = PoolStore.control_persist_snapshot([candidate])
      assert File.read!(index_path) == original_index
      assert {:ok, [snapshot]} = PoolStore.control_snapshot()
      assert snapshot.range_start == "192.0.2.20"
      assert snapshot.range_end == "192.0.2.100"
      assert snapshot.lease_time == 3600
    end
  end

  describe "default_file_path/0" do
    test "returns a path ending with pools.toml" do
      path = PoolStore.default_file_path()
      assert String.ends_with?(path, "pools.toml")
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

  defp use_data_dir(tmp_dir) do
    previous = Application.get_env(:yellow_dog, :data_dir)
    Application.put_env(:yellow_dog, :data_dir, tmp_dir)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:yellow_dog, :data_dir, previous),
        else: Application.delete_env(:yellow_dog, :data_dir)
    end)
  end
end
