defmodule YellowDog.Netman.PolicyEngineTest do
  use ExUnit.Case, async: true

  alias YellowDog.Netman.PolicyEngine

  describe "effective_priority/1" do
    test "adds type default for ethernet" do
      conn = %{type: :ethernet, autoconnect_priority: 50}
      assert PolicyEngine.effective_priority(conn) == 150
    end

    test "adds type default for wifi" do
      conn = %{type: :wifi, autoconnect_priority: 0}
      assert PolicyEngine.effective_priority(conn) == 50
    end

    test "adds type default for vpn" do
      conn = %{type: :vpn, autoconnect_priority: 0}
      assert PolicyEngine.effective_priority(conn) == 30
    end

    test "uses zero for unknown type" do
      conn = %{type: :unknown, autoconnect_priority: 10}
      assert PolicyEngine.effective_priority(conn) == 10
    end

    test "defaults to zero base priority" do
      conn = %{type: :ethernet}
      assert PolicyEngine.effective_priority(conn) == 100
    end
  end

  describe "default_route/1" do
    test "returns :none for empty list" do
      assert PolicyEngine.default_route([]) == :none
    end

    test "returns highest priority connection" do
      connections = [
        %{id: "wifi", type: :wifi, autoconnect_priority: 0},
        %{id: "eth0", type: :ethernet, autoconnect_priority: 100}
      ]

      assert {:ok, "eth0"} = PolicyEngine.default_route(connections)
    end

    test "ethernet beats wifi at same base priority" do
      connections = [
        %{id: "wifi", type: :wifi, autoconnect_priority: 0},
        %{id: "eth0", type: :ethernet, autoconnect_priority: 0}
      ]

      assert {:ok, "eth0"} = PolicyEngine.default_route(connections)
    end

    test "uses profile_id when available" do
      connections = [
        %{profile_id: "my-conn", type: :ethernet, autoconnect_priority: 0}
      ]

      assert {:ok, "my-conn"} = PolicyEngine.default_route(connections)
    end
  end

  describe "route_metrics/1" do
    test "higher priority gets lower metric" do
      connections = [
        %{id: "high", type: :ethernet, autoconnect_priority: 100},
        %{id: "low", type: :wifi, autoconnect_priority: 0}
      ]

      metrics = PolicyEngine.route_metrics(connections)
      assert metrics["high"] < metrics["low"]
    end

    test "metrics are clamped to valid range" do
      connections = [
        %{id: "very-high", type: :ethernet, autoconnect_priority: 2000}
      ]

      metrics = PolicyEngine.route_metrics(connections)
      assert metrics["very-high"] >= 1
    end

    test "empty list returns empty map" do
      assert PolicyEngine.route_metrics([]) == %{}
    end
  end

  describe "dns_priority/1" do
    test "higher priority connection DNS comes first" do
      connections = [
        %{id: "low", type: :wifi, autoconnect_priority: 0, dns: ["8.8.8.8"], interface: "wlan0"},
        %{
          id: "high",
          type: :ethernet,
          autoconnect_priority: 100,
          dns: ["192.168.1.1"],
          interface: "eth0"
        }
      ]

      result = PolicyEngine.dns_priority(connections)
      assert length(result) == 2
      assert hd(result).server == "192.168.1.1"
      assert hd(result).interface == "eth0"
    end

    test "empty connections returns empty list" do
      assert PolicyEngine.dns_priority([]) == []
    end

    test "connections without DNS are skipped" do
      connections = [
        %{id: "no-dns", type: :ethernet, autoconnect_priority: 0, dns: [], interface: "eth0"}
      ]

      assert PolicyEngine.dns_priority(connections) == []
    end

    test "connection with nil dns key uses empty list fallback" do
      connections = [
        %{id: "nil-dns", type: :ethernet, autoconnect_priority: 50, interface: "eth0"}
      ]

      assert PolicyEngine.dns_priority(connections) == []
    end
  end
end
