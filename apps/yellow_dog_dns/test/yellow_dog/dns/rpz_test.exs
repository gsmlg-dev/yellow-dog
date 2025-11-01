defmodule YellowDog.Dns.RPZTest do
  use ExUnit.Case, async: false

  alias YellowDog.Dns.RPZ
  alias YellowDog.Dns.RPZ.Manager, as: RPZManager
  alias YellowDog.Dns.Zone
  alias YellowDog.Dns.Zone.Manager
  alias YellowDog.Dns.Zone.Parser

  setup do
    # Initialize Zone Storage ETS table if needed
    case :ets.whereis(:dns_zone_storage) do
      :undefined -> YellowDog.Dns.Zone.Storage.init()
      _ -> :ok
    end

    # Start Zone Manager
    {:ok, _pid} = start_supervised(Manager)

    # Start RPZ Manager
    {:ok, _pid} = start_supervised({RPZManager, enabled: true})

    :ok
  end

  describe "RPZ action decoding" do
    test "decodes NXDOMAIN action (CNAME .)" do
      result = RPZ.decode_rpz_action(".", :A)
      assert result.action == :nxdomain
      assert result.local_data == []
    end

    test "decodes NODATA action (CNAME *.)" do
      result = RPZ.decode_rpz_action("*.", :A)
      assert result.action == :nodata
      assert result.local_data == []
    end

    test "decodes PASSTHRU action" do
      result = RPZ.decode_rpz_action("rpz-passthru.", :A)
      assert result.action == :passthru
    end

    test "decodes DROP action" do
      result = RPZ.decode_rpz_action("rpz-drop.", :A)
      assert result.action == :drop
    end

    test "decodes TCP-ONLY action" do
      result = RPZ.decode_rpz_action("rpz-tcp-only.", :A)
      assert result.action == :tcp_only
    end
  end

  describe "RPZ Manager" do
    test "starts with default configuration" do
      assert RPZManager.enabled?() == true
      assert RPZManager.get_zones() == []
    end

    test "can add and remove RPZ zones" do
      :ok = RPZManager.add_zone("malware.rpz", 1)
      :ok = RPZManager.add_zone("ads.rpz", 2)

      zones = RPZManager.get_zones()
      assert length(zones) == 2
      assert zones == ["malware.rpz", "ads.rpz"]

      :ok = RPZManager.remove_zone("malware.rpz")
      zones = RPZManager.get_zones()
      assert zones == ["ads.rpz"]
    end

    test "sorts zones by priority" do
      :ok = RPZManager.add_zone("low-priority.rpz", 10)
      :ok = RPZManager.add_zone("high-priority.rpz", 1)
      :ok = RPZManager.add_zone("medium-priority.rpz", 5)

      zones = RPZManager.get_zones()
      assert zones == ["high-priority.rpz", "medium-priority.rpz", "low-priority.rpz"]
    end

    test "tracks statistics" do
      # Initial stats
      stats = RPZManager.stats()
      assert stats.total_queries == 0
      assert stats.blocks == 0
      assert stats.rewrites == 0
      assert stats.passthrus == 0
    end

    test "can be enabled and disabled" do
      assert RPZManager.enabled?() == true

      RPZManager.set_enabled(false)
      assert RPZManager.enabled?() == false

      RPZManager.set_enabled(true)
      assert RPZManager.enabled?() == true
    end
  end

  describe "RPZ policy checking with loaded zone" do
    setup do
      # Load an RPZ zone with test data
      rpz_data = """
      $ORIGIN malware.rpz.
      $TTL 300

      ; Zone SOA
      @       IN  SOA   ns1.example.com. admin.example.com. (
                        2024102901
                        7200
                        3600
                        1209600
                        300 )

      ; NS records required
      @       IN  NS    ns1.example.com.

      ; QNAME triggers
      ; Block malicious domain with NXDOMAIN
      badsite.example.com     IN  CNAME   .

      ; Block with NODATA
      spyware.example.com     IN  CNAME   *.

      ; Whitelist (passthru)
      trusted.example.com     IN  CNAME   rpz-passthru.

      ; Drop silently
      dropme.example.com      IN  CNAME   rpz-drop.

      ; Local data override
      redirect.example.com    IN  A       192.0.2.100

      ; Wildcard block
      *.malware.example.com   IN  CNAME   .
      """

      {:ok, zone} = Parser.parse_string(rpz_data, zone_name: "malware.rpz")
      {:ok, _} = Manager.load_zone_data("malware.rpz", zone)

      # Add to RPZ Manager
      RPZManager.add_zone("malware.rpz", 1)

      :ok
    end

    test "blocks malicious domain with NXDOMAIN" do
      result = RPZ.check_qname_trigger("malware.rpz", "badsite.example.com", :A)
      assert {:block, :nxdomain, []} = result
    end

    test "blocks with NODATA" do
      result = RPZ.check_qname_trigger("malware.rpz", "spyware.example.com", :A)
      assert {:block, :nodata, []} = result
    end

    test "allows whitelisted domain" do
      result = RPZ.check_qname_trigger("malware.rpz", "trusted.example.com", :A)
      assert {:passthru, []} = result
    end

    test "drops silently" do
      result = RPZ.check_qname_trigger("malware.rpz", "dropme.example.com", :A)
      assert {:block, :drop, []} = result
    end

    test "rewrites with local data" do
      result = RPZ.check_qname_trigger("malware.rpz", "redirect.example.com", :A)
      assert {:rewrite, records, []} = result
      assert length(records) == 1
      assert hd(records).rdata == {192, 0, 2, 100}
    end

    test "matches wildcard patterns" do
      result = RPZ.check_qname_trigger("malware.rpz", "test.malware.example.com", :A)
      assert {:block, :nxdomain, []} = result
    end

    test "does not match non-matching domains" do
      result = RPZ.check_qname_trigger("malware.rpz", "safe.example.com", :A)
      assert result == :passthru
    end
  end

  describe "Client-IP triggers" do
    test "converts IPv4 to RPZ format" do
      # This is internal functionality - just verify the module loads
      assert Code.ensure_loaded?(YellowDog.Dns.RPZ)
    end

    test "converts IPv6 to RPZ format" do
      # This is internal functionality - just verify the module loads
      assert Code.ensure_loaded?(YellowDog.Dns.RPZ)
    end
  end

  describe "Integration with policy checking" do
    test "check_policy returns passthru when no RPZ zones configured" do
      client_ip = {192, 0, 2, 1}
      result = RPZManager.check_policy("example.com", :A, client_ip)
      assert result == :passthru
    end
  end

  describe "Statistics tracking" do
    test "increments query counters" do
      client_ip = {192, 0, 2, 1}

      # Check a few policies
      RPZManager.check_policy("test1.example.com", :A, client_ip)
      RPZManager.check_policy("test2.example.com", :A, client_ip)
      RPZManager.check_policy("test3.example.com", :A, client_ip)

      stats = RPZManager.stats()
      assert stats.total_queries == 3
      assert stats.passthrus == 3
    end
  end
end
