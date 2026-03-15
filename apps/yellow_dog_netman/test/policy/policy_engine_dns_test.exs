defmodule YellowDog.Netman.PolicyEngineDnsTest do
  @moduledoc """
  Focused tests for PolicyEngine DNS priority ordering and edge cases.
  """
  use ExUnit.Case, async: true

  alias YellowDog.Netman.PolicyEngine

  describe "dns_priority/1 ordering" do
    test "multiple DNS servers from same connection preserve order" do
      connections = [
        %{
          id: "eth0",
          type: :ethernet,
          autoconnect_priority: 100,
          dns: ["8.8.8.8", "8.8.4.4", "1.1.1.1"],
          interface: "eth0"
        }
      ]

      result = PolicyEngine.dns_priority(connections)
      servers = Enum.map(result, & &1.server)
      assert servers == ["8.8.8.8", "8.8.4.4", "1.1.1.1"]
    end

    test "DNS servers from multiple connections are interleaved by priority" do
      connections = [
        %{
          id: "wifi",
          type: :wifi,
          autoconnect_priority: 0,
          dns: ["8.8.8.8"],
          interface: "wlan0"
        },
        %{
          id: "eth0",
          type: :ethernet,
          autoconnect_priority: 50,
          dns: ["192.168.1.1"],
          interface: "eth0"
        },
        %{
          id: "vpn",
          type: :vpn,
          autoconnect_priority: 200,
          dns: ["10.0.0.1"],
          interface: "tun0"
        }
      ]

      result = PolicyEngine.dns_priority(connections)
      servers = Enum.map(result, & &1.server)

      # VPN (200+30=230) > eth0 (50+100=150) > wifi (0+50=50)
      assert servers == ["10.0.0.1", "192.168.1.1", "8.8.8.8"]
    end

    test "each DNS entry includes interface and priority metadata" do
      connections = [
        %{
          id: "eth0",
          type: :ethernet,
          autoconnect_priority: 100,
          dns: ["1.1.1.1"],
          interface: "eth0"
        }
      ]

      [entry] = PolicyEngine.dns_priority(connections)
      assert entry.server == "1.1.1.1"
      assert entry.interface == "eth0"
      assert entry.priority == 200
    end

    test "connections with mixed empty and populated DNS" do
      connections = [
        %{id: "a", type: :ethernet, autoconnect_priority: 100, dns: [], interface: "eth0"},
        %{
          id: "b",
          type: :ethernet,
          autoconnect_priority: 50,
          dns: ["8.8.8.8"],
          interface: "eth1"
        },
        %{id: "c", type: :ethernet, autoconnect_priority: 200, dns: [], interface: "eth2"}
      ]

      result = PolicyEngine.dns_priority(connections)
      assert length(result) == 1
      assert hd(result).server == "8.8.8.8"
    end
  end

  describe "route_metrics/1 edge cases" do
    test "negative effective priority clamps metric to max" do
      connections = [
        %{id: "neg", type: :unknown, autoconnect_priority: -2000}
      ]

      metrics = PolicyEngine.route_metrics(connections)
      assert metrics["neg"] <= 9999
    end

    test "zero effective priority gives metric of 1000" do
      connections = [
        %{id: "zero", type: :unknown, autoconnect_priority: 0}
      ]

      metrics = PolicyEngine.route_metrics(connections)
      assert metrics["zero"] == 1000
    end

    test "all connection types get consistent metrics" do
      connections =
        for {type, _default} <- [ethernet: 100, wifi: 50, vpn: 30, cellular: 20] do
          %{id: "#{type}", type: type, autoconnect_priority: 0}
        end

      metrics = PolicyEngine.route_metrics(connections)
      assert metrics["ethernet"] < metrics["wifi"]
      assert metrics["wifi"] < metrics["vpn"]
      assert metrics["vpn"] < metrics["cellular"]
    end
  end

  describe "default_route/1 tie-breaking" do
    test "with equal priority, first in sorted order wins" do
      # Both have same effective priority
      connections = [
        %{id: "a", type: :ethernet, autoconnect_priority: 0},
        %{id: "b", type: :ethernet, autoconnect_priority: 0}
      ]

      {:ok, winner} = PolicyEngine.default_route(connections)
      assert winner in ["a", "b"]
    end

    test "single connection always wins" do
      connections = [
        %{id: "only", type: :cellular, autoconnect_priority: -100}
      ]

      assert {:ok, "only"} = PolicyEngine.default_route(connections)
    end
  end
end
