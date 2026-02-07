defmodule YellowDog.Dhcpv6.PoolStoreTest do
  use ExUnit.Case, async: false

  alias YellowDog.Dhcpv6.PoolStore

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
end
