defmodule YellowDog.Console.Settings.ServiceConfigurationTest do
  use ExUnit.Case, async: true

  alias YellowDog.Console.Settings.{AddressPool, ServiceConfiguration}

  describe "ServiceConfiguration changeset/2" do
    test "valid DNS configuration" do
      attrs = %{
        enabled: true,
        listen: "0.0.0.0",
        port: 53,
        service_type: :dns
      }

      changeset = ServiceConfiguration.changeset(%ServiceConfiguration{}, attrs)
      assert changeset.valid?
    end

    test "valid mDNS configuration with mode" do
      attrs = %{
        enabled: true,
        listen: "0.0.0.0",
        port: 5353,
        service_type: :mdns,
        mode: :responder
      }

      changeset = ServiceConfiguration.changeset(%ServiceConfiguration{}, attrs)
      assert changeset.valid?
    end

    test "requires listen, port, service_type" do
      changeset = ServiceConfiguration.changeset(%ServiceConfiguration{}, %{})

      refute changeset.valid?
      # Note: enabled has a default value of true, so it won't error
      assert %{listen: _, port: _, service_type: _} = errors_on(changeset)
    end

    test "validates port range" do
      attrs = %{
        enabled: true,
        listen: "0.0.0.0",
        port: 99999,
        service_type: :dns
      }

      changeset = ServiceConfiguration.changeset(%ServiceConfiguration{}, attrs)
      refute changeset.valid?
      assert %{port: _} = errors_on(changeset)
    end

    test "validates IP address format" do
      attrs = %{
        enabled: true,
        listen: "256.1.1.1",
        port: 53,
        service_type: :dns
      }

      changeset = ServiceConfiguration.changeset(%ServiceConfiguration{}, attrs)
      refute changeset.valid?
      assert %{listen: _} = errors_on(changeset)
    end

    test "mDNS requires mode field" do
      attrs = %{
        enabled: true,
        listen: "0.0.0.0",
        port: 5353,
        service_type: :mdns
        # Missing mode
      }

      changeset = ServiceConfiguration.changeset(%ServiceConfiguration{}, attrs)
      refute changeset.valid?
      assert %{mode: _} = errors_on(changeset)
    end

    test "mDNS validates mode values" do
      attrs = %{
        enabled: true,
        listen: "0.0.0.0",
        port: 5353,
        service_type: :mdns,
        mode: :invalid_mode
      }

      changeset = ServiceConfiguration.changeset(%ServiceConfiguration{}, attrs)
      refute changeset.valid?
    end

    test "DHCP requires at least one pool" do
      attrs = %{
        enabled: true,
        listen: "0.0.0.0",
        port: 67,
        service_type: :dhcpv4,
        pools: []
      }

      changeset = ServiceConfiguration.changeset(%ServiceConfiguration{}, attrs)
      refute changeset.valid?
      assert %{pools: _} = errors_on(changeset)
    end

    test "DHCP accepts valid pools" do
      pool_attrs = %{
        name: "default",
        range_start: "192.168.1.100",
        range_end: "192.168.1.200",
        lease_time: 3600,
        protocol: :ipv4
      }

      attrs = %{
        enabled: true,
        listen: "0.0.0.0",
        port: 67,
        service_type: :dhcpv4,
        pools: [pool_attrs]
      }

      changeset = ServiceConfiguration.changeset(%ServiceConfiguration{}, attrs)
      assert changeset.valid?
    end
  end

  describe "AddressPool changeset/2" do
    test "valid IPv4 pool" do
      attrs = %{
        name: "office",
        range_start: "192.168.1.100",
        range_end: "192.168.1.200",
        lease_time: 3600,
        gateway: "192.168.1.1",
        dns_servers: ["8.8.8.8"],
        protocol: :ipv4
      }

      changeset = AddressPool.changeset(%AddressPool{}, attrs)
      assert changeset.valid?
    end

    test "valid IPv6 pool" do
      attrs = %{
        name: "office-v6",
        range_start: "2001:db8::100",
        range_end: "2001:db8::200",
        preferred_lifetime: 3600,
        valid_lifetime: 7200,
        dns_servers: ["2001:4860:4860::8888"],
        protocol: :ipv6
      }

      changeset = AddressPool.changeset(%AddressPool{}, attrs)
      assert changeset.valid?
    end

    test "requires name, range_start, range_end, protocol" do
      changeset = AddressPool.changeset(%AddressPool{}, %{})

      refute changeset.valid?
      assert %{name: _, range_start: _, range_end: _, protocol: _} = errors_on(changeset)
    end

    test "IPv4 requires lease_time" do
      attrs = %{
        name: "office",
        range_start: "192.168.1.100",
        range_end: "192.168.1.200",
        protocol: :ipv4
        # Missing lease_time
      }

      changeset = AddressPool.changeset(%AddressPool{}, attrs)
      refute changeset.valid?
      assert %{lease_time: _} = errors_on(changeset)
    end

    test "IPv4 validates lease_time minimum" do
      attrs = %{
        name: "office",
        range_start: "192.168.1.100",
        range_end: "192.168.1.200",
        lease_time: 30,
        protocol: :ipv4
      }

      changeset = AddressPool.changeset(%AddressPool{}, attrs)
      refute changeset.valid?
      assert %{lease_time: _} = errors_on(changeset)
    end

    test "IPv6 requires preferred_lifetime and valid_lifetime" do
      attrs = %{
        name: "office-v6",
        range_start: "2001:db8::100",
        range_end: "2001:db8::200",
        protocol: :ipv6
        # Missing lifetimes
      }

      changeset = AddressPool.changeset(%AddressPool{}, attrs)
      refute changeset.valid?
      assert %{preferred_lifetime: _, valid_lifetime: _} = errors_on(changeset)
    end

    test "IPv6 validates preferred_lifetime <= valid_lifetime" do
      attrs = %{
        name: "office-v6",
        range_start: "2001:db8::100",
        range_end: "2001:db8::200",
        preferred_lifetime: 7200,
        valid_lifetime: 3600,
        protocol: :ipv6
      }

      changeset = AddressPool.changeset(%AddressPool{}, attrs)
      refute changeset.valid?
      assert %{preferred_lifetime: _} = errors_on(changeset)
    end

    test "validates IP range (start < end)" do
      attrs = %{
        name: "office",
        range_start: "192.168.1.200",
        range_end: "192.168.1.100",
        lease_time: 3600,
        protocol: :ipv4
      }

      changeset = AddressPool.changeset(%AddressPool{}, attrs)
      refute changeset.valid?
      assert %{range_start: _} = errors_on(changeset)
    end

    test "validates DNS servers are valid IPs" do
      attrs = %{
        name: "office",
        range_start: "192.168.1.100",
        range_end: "192.168.1.200",
        lease_time: 3600,
        dns_servers: ["invalid", "256.1.1.1"],
        protocol: :ipv4
      }

      changeset = AddressPool.changeset(%AddressPool{}, attrs)
      refute changeset.valid?
      assert %{dns_servers: _} = errors_on(changeset)
    end
  end

  # Helper to get errors from changeset
  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
  end
end
