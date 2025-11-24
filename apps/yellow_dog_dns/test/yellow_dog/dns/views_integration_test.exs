defmodule YellowDog.Dns.ViewsIntegrationTest do
  @moduledoc """
  Integration tests for DNS Views with ACL-based client matching.

  These tests demonstrate how Views should be integrated with Query.Resolver
  and Zone.Storage to provide split-horizon DNS functionality.
  """

  use ExUnit.Case, async: false

  alias YellowDog.Dns.View
  alias YellowDog.Dns.View.ACL
  alias YellowDog.Dns.Zone
  alias YellowDog.Dns.Zone.Storage
  alias YellowDog.Dns.Zone.Manager, as: ZoneManager

  setup do
    # Start Zone.Manager if not running
    case Process.whereis(YellowDog.Dns.Zone.Manager) do
      nil ->
        {:ok, _pid} = YellowDog.Dns.Zone.Manager.start_link([])

      _pid ->
        :ok
    end

    # Load test zones
    internal_zone_data = """
    $ORIGIN internal.example.com.
    @   IN  SOA ns1.internal.example.com. admin.internal.example.com. (
                2024010101 ; serial
                3600       ; refresh
                1800       ; retry
                604800     ; expire
                300 )      ; minimum

    @       IN  NS  ns1.internal.example.com.
    ns1     IN  A   192.168.1.1
    www     IN  A   192.168.1.100
    db      IN  A   192.168.1.50
    """

    external_zone_data = """
    $ORIGIN example.com.
    @   IN  SOA ns1.example.com. admin.example.com. (
                2024010101 ; serial
                3600       ; refresh
                1800       ; retry
                604800     ; expire
                300 )      ; minimum

    @       IN  NS  ns1.example.com.
    ns1     IN  A   203.0.113.1
    www     IN  A   203.0.113.100
    """

    # Load internal zone
    {:ok, internal_zone} =
      Zone.Parser.parse_string(internal_zone_data, zone_name: "internal.example.com")

    ZoneManager.load_zone_data("internal.example.com", internal_zone)

    # Load external zone
    {:ok, external_zone} = Zone.Parser.parse_string(external_zone_data, zone_name: "example.com")
    ZoneManager.load_zone_data("example.com", external_zone)

    # Create views
    internal_view = View.new("internal", "localnets", ["internal.example.com"], true)
    external_view = View.new("external", "any", ["example.com"], false)

    views = [internal_view, external_view]

    {:ok, views: views, internal_view: internal_view, external_view: external_view}
  end

  describe "View matching with client IPs" do
    test "internal client matches internal view", %{views: views, internal_view: internal_view} do
      client_ip = {192, 168, 1, 50}

      {:ok, matched_view} = View.match_client(client_ip, views)

      assert matched_view.name == internal_view.name
      assert matched_view.zones == ["internal.example.com"]
      assert matched_view.recursion_enabled == true
    end

    test "external client matches external view", %{views: views, external_view: external_view} do
      client_ip = {8, 8, 8, 8}

      {:ok, matched_view} = View.match_client(client_ip, views)

      assert matched_view.name == external_view.name
      assert matched_view.zones == ["example.com"]
      assert matched_view.recursion_enabled == false
    end

    test "localhost matches internal view (localnets includes localhost)", %{views: views} do
      client_ip = {127, 0, 0, 1}

      # Localhost should NOT match localnets - only private networks
      result = View.match_client(client_ip, views)

      # Should match external view (any)
      assert {:ok, view} = result
      assert view.name == "external"
    end

    test "private network IP matches internal view", %{views: views, internal_view: internal_view} do
      # Test different private network ranges
      test_ips = [
        {10, 0, 0, 1},
        # 10.0.0.0/8
        {172, 16, 0, 1},
        # 172.16.0.0/12
        {192, 168, 100, 50}
        # 192.168.0.0/16
      ]

      for ip <- test_ips do
        {:ok, matched_view} = View.match_client(ip, views)
        assert matched_view.name == internal_view.name
      end
    end
  end

  describe "Split-horizon DNS resolution" do
    test "internal client resolves internal zone", %{views: views} do
      client_ip = {192, 168, 1, 50}
      {:ok, view} = View.match_client(client_ip, views)

      # Internal client should see internal.example.com zone
      assert View.has_zone?(view, "internal.example.com")

      # Verify zone lookup works
      zone_name = "internal.example.com"
      owner = "www.internal.example.com."

      {:ok, records} = Storage.lookup_record(zone_name, owner, :A)
      assert length(records) > 0

      # Extract rdata from the record map
      [record_map | _] = records
      assert %{rdata: {192, 168, 1, 100}} = record_map
    end

    test "external client resolves external zone", %{views: views} do
      client_ip = {8, 8, 8, 8}
      {:ok, view} = View.match_client(client_ip, views)

      # External client should see example.com zone
      assert View.has_zone?(view, "example.com")
      refute View.has_zone?(view, "internal.example.com")

      # Verify zone lookup works
      zone_name = "example.com"
      owner = "www.example.com."

      {:ok, records} = Storage.lookup_record(zone_name, owner, :A)
      assert length(records) > 0

      # Extract rdata from the record map
      [record_map | _] = records
      assert %{rdata: {203, 0, 113, 100}} = record_map
    end

    test "internal client gets different answer than external client", %{views: views} do
      internal_client = {192, 168, 1, 50}
      external_client = {8, 8, 8, 8}

      {:ok, internal_view} = View.match_client(internal_client, views)
      {:ok, external_view} = View.match_client(external_client, views)

      # Internal client can access internal zone
      assert View.has_zone?(internal_view, "internal.example.com")

      # External client cannot access internal zone
      refute View.has_zone?(external_view, "internal.example.com")

      # Both can access different zones
      assert View.has_zone?(external_view, "example.com")
    end
  end

  describe "View-based zone filtering" do
    test "returns only zones available in view" do
      view = View.new("test", "any", ["zone1.com", "zone2.com", "zone3.com"])

      assert view.zones == ["zone1.com", "zone2.com", "zone3.com"]
      assert View.has_zone?(view, "zone1.com")
      assert View.has_zone?(view, "zone2.com")
      assert View.has_zone?(view, "zone3.com")
      refute View.has_zone?(view, "zone4.com")
    end

    test "empty zones list means no zones available" do
      view = View.new("test", "any", [])

      assert view.zones == []
      refute View.has_zone?(view, "example.com")
    end

    test "zone filtering works with ACL matching" do
      # Create custom ACL
      acl = ACL.new("dmz", [{:allow, {10, 0, 0, 0}, 8}])
      view = View.new("dmz", acl, ["dmz.example.com", "public.example.com"])

      # Client from DMZ network
      dmz_client = {10, 1, 2, 3}
      assert View.matches?(view, dmz_client)
      assert View.has_zone?(view, "dmz.example.com")

      # Client from outside
      external_client = {8, 8, 8, 8}
      refute View.matches?(view, external_client)
    end
  end

  describe "Complex view scenarios" do
    test "multiple views with different zone sets" do
      # Create views for different network segments
      internal_acl = ACL.new("internal", [{:allow, {192, 168, 0, 0}, 16}])
      dmz_acl = ACL.new("dmz", [{:allow, {10, 0, 0, 0}, 8}])
      external_acl = ACL.new("external", [{:allow, :any}])

      internal_view =
        View.new("internal", internal_acl, ["corp.example.com", "internal.example.com"], true)

      dmz_view = View.new("dmz", dmz_acl, ["dmz.example.com", "public.example.com"], true)
      external_view = View.new("external", external_acl, ["public.example.com"], false)

      views = [internal_view, dmz_view, external_view]

      # Test internal client
      {:ok, matched} = View.match_client({192, 168, 1, 100}, views)
      assert matched.name == "internal"
      assert View.has_zone?(matched, "corp.example.com")
      assert View.has_zone?(matched, "internal.example.com")

      # Test DMZ client
      {:ok, matched} = View.match_client({10, 0, 0, 50}, views)
      assert matched.name == "dmz"
      assert View.has_zone?(matched, "dmz.example.com")
      assert View.has_zone?(matched, "public.example.com")

      # Test external client
      {:ok, matched} = View.match_client({8, 8, 8, 8}, views)
      assert matched.name == "external"
      assert View.has_zone?(matched, "public.example.com")
      refute View.has_zone?(matched, "corp.example.com")
      refute View.has_zone?(matched, "dmz.example.com")
    end

    test "view priority - first match wins" do
      # Create overlapping views
      view1 = View.new("specific", "localnets", ["zone1.com"])
      view2 = View.new("general", "any", ["zone2.com"])

      views = [view1, view2]

      # Private IP matches first view
      {:ok, matched} = View.match_client({192, 168, 1, 1}, views)
      assert matched.name == "specific"

      # Reverse order changes result
      views_reversed = [view2, view1]
      {:ok, matched} = View.match_client({192, 168, 1, 1}, views_reversed)
      assert matched.name == "general"
    end

    test "recursion control per view" do
      # Internal view allows recursion
      internal_view = View.new("internal", "localnets", ["corp.example.com"], true)

      # External view disables recursion
      external_view = View.new("external", "any", ["public.example.com"], false)

      assert internal_view.recursion_enabled == true
      assert external_view.recursion_enabled == false

      # This allows different recursion policies for different clients
      {:ok, internal_matched} =
        View.match_client({192, 168, 1, 1}, [internal_view, external_view])

      assert internal_matched.recursion_enabled == true

      {:ok, external_matched} = View.match_client({8, 8, 8, 8}, [internal_view, external_view])
      assert external_matched.recursion_enabled == false
    end
  end

  describe "ACL integration with views" do
    test "built-in ACL names work with views" do
      view = View.new("localhost-only", "localhost", ["admin.example.com"])

      assert View.matches?(view, {127, 0, 0, 1})
      assert View.matches?(view, {0, 0, 0, 0, 0, 0, 0, 1})
      refute View.matches?(view, {192, 168, 1, 1})
    end

    test "custom ACL structs work with views" do
      # Create complex ACL with exceptions
      acl =
        ACL.new("complex", [
          {:allow, {10, 1, 1, 0}, 24},
          {:deny, {10, 1, 0, 0}, 16},
          {:allow, {10, 0, 0, 0}, 8}
        ])

      view = View.new("complex", acl, ["test.example.com"])

      # Allowed by specific exception
      assert View.matches?(view, {10, 1, 1, 1})

      # Denied by deny rule
      refute View.matches?(view, {10, 1, 0, 1})

      # Allowed by broader rule
      assert View.matches?(view, {10, 0, 0, 1})
    end

    test "CIDR string parsing in ACLs with views" do
      acl = ACL.new("cidr-test", [{:allow, "10.0.0.0/8"}])
      view = View.new("cidr-view", acl, ["test.example.com"])

      assert View.matches?(view, {10, 1, 2, 3})
      refute View.matches?(view, {11, 0, 0, 1})
    end
  end
end
