defmodule YellowDog.Dns.RootZone.HintsTest do
  use ExUnit.Case, async: true

  alias YellowDog.Dns.RootZone.Hints

  doctest Hints

  describe "get_root_servers_ipv4/0" do
    test "returns 13 IPv4 root servers" do
      servers = Hints.get_root_servers_ipv4()

      assert length(servers) == 13
      assert is_list(servers)

      # Verify each server has name and IPv4 tuple
      Enum.each(servers, fn {name, ip} ->
        assert is_binary(name)
        assert String.contains?(name, "root-servers.net")
        assert is_tuple(ip)
        assert tuple_size(ip) == 4
      end)
    end

    test "contains a.root-servers.net with correct IPv4" do
      servers = Hints.get_root_servers_ipv4()

      assert {"a.root-servers.net", {198, 41, 0, 4}} in servers
    end

    test "all root servers a-m are present" do
      servers = Hints.get_root_servers_ipv4()
      names = Enum.map(servers, fn {name, _ip} -> name end)

      for letter <- ?a..?m do
        expected_name = "#{<<letter>>}.root-servers.net"
        assert expected_name in names
      end
    end
  end

  describe "get_root_servers_ipv6/0" do
    test "returns 13 IPv6 root servers" do
      servers = Hints.get_root_servers_ipv6()

      assert length(servers) == 13
      assert is_list(servers)

      # Verify each server has name and IPv6 tuple
      Enum.each(servers, fn {name, ip} ->
        assert is_binary(name)
        assert String.contains?(name, "root-servers.net")
        assert is_tuple(ip)
        assert tuple_size(ip) == 8
      end)
    end

    test "contains a.root-servers.net with IPv6" do
      servers = Hints.get_root_servers_ipv6()
      names = Enum.map(servers, fn {name, _ip} -> name end)

      assert "a.root-servers.net" in names
    end
  end

  describe "get_root_servers/0" do
    test "returns both IPv4 and IPv6 servers (26 total)" do
      servers = Hints.get_root_servers()

      assert length(servers) == 26
      assert is_list(servers)
    end

    test "includes both IPv4 and IPv6 addresses" do
      servers = Hints.get_root_servers()

      ipv4_count =
        Enum.count(servers, fn {_name, ip} ->
          tuple_size(ip) == 4
        end)

      ipv6_count =
        Enum.count(servers, fn {_name, ip} ->
          tuple_size(ip) == 8
        end)

      assert ipv4_count == 13
      assert ipv6_count == 13
    end
  end

  describe "get_ipv4_addresses/0" do
    test "returns only IPv4 addresses without names" do
      addresses = Hints.get_ipv4_addresses()

      assert length(addresses) == 13

      Enum.each(addresses, fn ip ->
        assert is_tuple(ip)
        assert tuple_size(ip) == 4
      end)
    end

    test "contains expected IPv4 addresses" do
      addresses = Hints.get_ipv4_addresses()

      assert {198, 41, 0, 4} in addresses
      assert {199, 9, 14, 201} in addresses
      assert {192, 33, 4, 12} in addresses
    end
  end

  describe "get_ipv6_addresses/0" do
    test "returns only IPv6 addresses without names" do
      addresses = Hints.get_ipv6_addresses()

      assert length(addresses) == 13

      Enum.each(addresses, fn ip ->
        assert is_tuple(ip)
        assert tuple_size(ip) == 8
      end)
    end
  end

  describe "get_all_addresses/0" do
    test "returns all 26 addresses" do
      addresses = Hints.get_all_addresses()

      assert length(addresses) == 26
    end

    test "includes both IPv4 and IPv6" do
      addresses = Hints.get_all_addresses()

      ipv4_count = Enum.count(addresses, fn ip -> tuple_size(ip) == 4 end)
      ipv6_count = Enum.count(addresses, fn ip -> tuple_size(ip) == 8 end)

      assert ipv4_count == 13
      assert ipv6_count == 13
    end
  end

  describe "get_server/1" do
    test "returns IPv4 address for known server" do
      assert {:ok, {198, 41, 0, 4}} = Hints.get_server("a.root-servers.net")
    end

    test "returns error for unknown server" do
      assert {:error, :not_found} = Hints.get_server("invalid.root-servers.net")
    end

    test "finds all root servers a-m" do
      for letter <- ?a..?m do
        name = "#{<<letter>>}.root-servers.net"
        assert {:ok, _ip} = Hints.get_server(name)
      end
    end
  end

  describe "count/0" do
    test "returns correct counts" do
      counts = Hints.count()

      assert counts.ipv4 == 13
      assert counts.ipv6 == 13
      assert counts.total == 26
    end

    test "returns a map with expected keys" do
      counts = Hints.count()

      assert Map.has_key?(counts, :ipv4)
      assert Map.has_key?(counts, :ipv6)
      assert Map.has_key?(counts, :total)
    end
  end
end
