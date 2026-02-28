defmodule YellowDog.Netman.Integration.ProfileSelectionTest do
  @moduledoc """
  Integration tests for profile matching and priority-based selection.
  """
  use ExUnit.Case

  alias YellowDog.Netman.ProfileStore
  alias YellowDog.Netman.ReconciliationEngine
  alias YellowDog.Netman.Test.MockNetlink
  alias YellowDog.Netman.Types.Profile

  @moduletag :capture_log

  test "match_interface prefers exact interface match over wildcard" do
    iface = "psel_eth#{:rand.uniform(65535)}"

    exact_profile = %Profile{
      id: "exact-#{iface}",
      type: :ethernet,
      interface: iface,
      autoconnect: true,
      autoconnect_priority: 50,
      ethernet: %{mtu: nil},
      ipv4: %{method: :disabled, address: nil, gateway: nil, dns: []},
      ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
    }

    wildcard_profile = %Profile{
      id: "wildcard-#{iface}",
      type: :ethernet,
      interface: nil,
      autoconnect: true,
      autoconnect_priority: 500,
      ethernet: %{mtu: nil},
      ipv4: %{method: :disabled, address: nil, gateway: nil, dns: []},
      ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
    }

    ProfileStore.put(exact_profile.id, exact_profile)
    ProfileStore.put(wildcard_profile.id, wildcard_profile)

    matched = ProfileStore.match_interface(iface)
    # Exact interface match should win over wildcard, even with lower priority
    assert matched.id == exact_profile.id

    ProfileStore.delete(exact_profile.id)
    ProfileStore.delete(wildcard_profile.id)
  end

  test "match_interface returns wildcard profile when no exact match" do
    iface = "psel_unm#{:rand.uniform(65535)}"

    wildcard_profile = %Profile{
      id: "wc-#{iface}",
      type: :ethernet,
      interface: nil,
      autoconnect: true,
      autoconnect_priority: 100,
      ethernet: %{mtu: nil},
      ipv4: %{method: :disabled, address: nil, gateway: nil, dns: []},
      ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
    }

    ProfileStore.put(wildcard_profile.id, wildcard_profile)

    matched = ProfileStore.match_interface(iface)
    assert matched.id == wildcard_profile.id

    ProfileStore.delete(wildcard_profile.id)
  end

  test "match_interface returns nil when no profile matches type" do
    iface = "psel_wifi#{:rand.uniform(65535)}"

    wifi_profile = %Profile{
      id: "wifi-#{iface}",
      type: :wifi,
      interface: iface,
      autoconnect: true,
      autoconnect_priority: 100,
      ethernet: %{mtu: nil},
      ipv4: %{method: :disabled, address: nil, gateway: nil, dns: []},
      ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
    }

    ProfileStore.put(wifi_profile.id, wifi_profile)

    # match_interface defaults to :ethernet type
    matched = ProfileStore.match_interface(iface)
    assert matched == nil

    ProfileStore.delete(wifi_profile.id)
  end

  test "two wildcard profiles sorted by priority" do
    wildcard_hi = %Profile{
      id: "wc-hi-#{:rand.uniform(65535)}",
      type: :ethernet,
      interface: nil,
      autoconnect: true,
      autoconnect_priority: 500,
      ethernet: %{mtu: nil},
      ipv4: %{method: :disabled, address: nil, gateway: nil, dns: []},
      ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
    }

    wildcard_lo = %Profile{
      id: "wc-lo-#{:rand.uniform(65535)}",
      type: :ethernet,
      interface: nil,
      autoconnect: true,
      autoconnect_priority: 50,
      ethernet: %{mtu: nil},
      ipv4: %{method: :disabled, address: nil, gateway: nil, dns: []},
      ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
    }

    ProfileStore.put(wildcard_hi.id, wildcard_hi)
    ProfileStore.put(wildcard_lo.id, wildcard_lo)

    iface = "psel_any#{:rand.uniform(65535)}"
    matched = ProfileStore.match_interface(iface)
    # Higher priority wildcard should win
    assert matched.id == wildcard_hi.id

    ProfileStore.delete(wildcard_hi.id)
    ProfileStore.delete(wildcard_lo.id)
  end

  test "compute_desired only includes autoconnect profiles with matching links" do
    iface = "psel_des#{:rand.uniform(65535)}"

    auto_profile = %Profile{
      id: "auto-#{iface}",
      type: :ethernet,
      interface: iface,
      autoconnect: true,
      autoconnect_priority: 100,
      ethernet: %{mtu: nil},
      ipv4: %{method: :disabled, address: nil, gateway: nil, dns: []},
      ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
    }

    manual_profile = %Profile{
      id: "manual-#{iface}",
      type: :ethernet,
      interface: iface,
      autoconnect: false,
      autoconnect_priority: 200,
      ethernet: %{mtu: nil},
      ipv4: %{method: :disabled, address: nil, gateway: nil, dns: []},
      ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
    }

    ProfileStore.put(auto_profile.id, auto_profile)
    ProfileStore.put(manual_profile.id, manual_profile)

    MockNetlink.link_up(iface, carrier: true)
    Process.sleep(50)

    desired = ReconciliationEngine.compute_desired()

    # Only autoconnect profile should appear in desired state
    assert Map.has_key?(desired.connections, auto_profile.id)
    refute Map.has_key?(desired.connections, manual_profile.id)

    ProfileStore.delete(auto_profile.id)
    ProfileStore.delete(manual_profile.id)
    MockNetlink.link_removed(iface)
  end
end
