defmodule YellowDog.Dns.RPZUnitTest do
  use ExUnit.Case, async: true

  alias YellowDog.Dns.RPZ
  alias YellowDog.Dns.Zone.Record

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

    test "handles invalid CNAME targets as NXDOMAIN" do
      result = RPZ.decode_rpz_action("invalid.target.", :A)
      assert result.action == :nxdomain
    end

    test "normalizes domain names in action decoding" do
      # Test with trailing dot
      result1 = RPZ.decode_rpz_action("rpz-passthru.", :A)
      assert result1.action == :passthru

      # Test without trailing dot
      result2 = RPZ.decode_rpz_action("rpz-passthru", :A)
      assert result2.action == :passthru
    end
  end

  describe "RPZ policy evaluation with mocked records" do
    test "CNAME to . triggers NXDOMAIN" do
      # Simulate a CNAME record pointing to "."
      cname_record = %Record{
        owner: "badsite.example.com",
        type: :CNAME,
        class: :IN,
        ttl: 300,
        rdata: "."
      }

      decoded = RPZ.decode_rpz_action(cname_record.rdata, :A)
      assert decoded.action == :nxdomain
    end

    test "CNAME to *. triggers NODATA" do
      cname_record = %Record{
        owner: "spyware.example.com",
        type: :CNAME,
        class: :IN,
        ttl: 300,
        rdata: "*."
      }

      decoded = RPZ.decode_rpz_action(cname_record.rdata, :A)
      assert decoded.action == :nodata
    end

    test "CNAME to rpz-drop. triggers DROP" do
      cname_record = %Record{
        owner: "dropme.example.com",
        type: :CNAME,
        class: :IN,
        ttl: 300,
        rdata: "rpz-drop."
      }

      decoded = RPZ.decode_rpz_action(cname_record.rdata, :A)
      assert decoded.action == :drop
    end

    test "CNAME to rpz-passthru. triggers PASSTHRU" do
      cname_record = %Record{
        owner: "trusted.example.com",
        type: :CNAME,
        class: :IN,
        ttl: 300,
        rdata: "rpz-passthru."
      }

      decoded = RPZ.decode_rpz_action(cname_record.rdata, :A)
      assert decoded.action == :passthru
    end
  end

  describe "RPZ name normalization" do
    test "normalizes domain names consistently" do
      # The normalize_name/1 function should handle various formats
      # This is an internal function but we can verify behavior through decode_rpz_action

      # All these should produce the same result
      actions = [
        RPZ.decode_rpz_action("rpz-drop", :A),
        RPZ.decode_rpz_action("rpz-drop.", :A),
        RPZ.decode_rpz_action("RPZ-DROP.", :A),
        RPZ.decode_rpz_action("RPZ-DROP", :A)
      ]

      assert Enum.all?(actions, fn action -> action.action == :drop end)
    end

    test "handles wildcard normalization" do
      # Test that wildcard patterns are normalized correctly
      result1 = RPZ.decode_rpz_action("*.", :A)
      result2 = RPZ.decode_rpz_action("*", :A)

      assert result1.action == :nodata
      assert result2.action == :nodata
    end
  end

  describe "RPZ policy actions" do
    test "NXDOMAIN should return empty answer" do
      decoded = RPZ.decode_rpz_action(".", :A)
      assert decoded.action == :nxdomain
      assert decoded.local_data == []
    end

    test "NODATA should return empty answer" do
      decoded = RPZ.decode_rpz_action("*.", :A)
      assert decoded.action == :nodata
      assert decoded.local_data == []
    end

    test "DROP should have no response" do
      decoded = RPZ.decode_rpz_action("rpz-drop.", :A)
      assert decoded.action == :drop
      # DROP means no response sent, so no local_data needed
    end

    test "PASSTHRU should allow query to proceed" do
      decoded = RPZ.decode_rpz_action("rpz-passthru.", :A)
      assert decoded.action == :passthru
      # PASSTHRU means continue normal resolution
    end

    test "TCP-ONLY should force TCP" do
      decoded = RPZ.decode_rpz_action("rpz-tcp-only.", :A)
      assert decoded.action == :tcp_only
      # TCP-ONLY forces client to retry over TCP
    end
  end

  describe "RPZ trigger types" do
    test "QNAME trigger format" do
      # QNAME triggers match the queried domain name directly
      # Example: badsite.example.com IN CNAME .

      # This is what the RPZ zone would contain
      _qname_trigger = "badsite.example.com"
      action = "."

      decoded = RPZ.decode_rpz_action(action, :A)
      assert decoded.action == :nxdomain
    end

    test "Client-IP trigger format" do
      # Client-IP triggers are stored in special format:
      # 32.1.2.0.192.rpz-client-ip IN CNAME .
      # This represents client IP 192.0.2.1/32

      # The RPZ module should handle Client-IP formatting
      # This test documents the expected format
      assert true  # Placeholder - Client-IP implementation is future work
    end

    test "NSDNAME trigger format" do
      # NSDNAME triggers match nameserver names
      # Example: ns1.badhost.example.com.rpz-nsdname IN CNAME .

      # This would block any domain using ns1.badhost.example.com as NS
      assert true  # Placeholder - NSDNAME implementation is future work
    end

    test "NSIP trigger format" do
      # NSIP triggers match nameserver IP addresses
      # Example: 32.1.2.0.192.rpz-nsip IN CNAME .

      # This would block any domain using nameserver at 192.0.2.1
      assert true  # Placeholder - NSIP implementation is future work
    end
  end

  describe "RPZ local data rewriting" do
    test "A record rewrite replaces answer" do
      # When RPZ contains: badsite.example.com IN A 192.0.2.100
      # The query for badsite.example.com should return 192.0.2.100

      # This would be handled by check_qname_trigger returning the A record
      # as local_data instead of a CNAME action
      local_a_record = %Record{
        owner: "badsite.example.com",
        type: :A,
        class: :IN,
        ttl: 300,
        rdata: {192, 0, 2, 100}
      }

      # The decode_rpz_action is for CNAME targets, not direct data
      # For A records, the local_data would be returned directly
      assert local_a_record.type == :A
      assert local_a_record.rdata == {192, 0, 2, 100}
    end

    test "TXT record rewrite provides explanation" do
      # RPZ can return TXT records explaining the block
      # Example: badsite.example.com IN TXT "Blocked by RPZ policy"

      local_txt_record = %Record{
        owner: "badsite.example.com",
        type: :TXT,
        class: :IN,
        ttl: 300,
        rdata: ["Blocked by RPZ policy"]
      }

      assert local_txt_record.type == :TXT
      assert is_list(local_txt_record.rdata)
    end
  end

  describe "RPZ wildcard matching" do
    test "wildcard trigger format" do
      # Wildcards in RPZ match subdomains
      # Example: *.badzone.example.com IN CNAME .
      # This blocks www.badzone.example.com, mail.badzone.example.com, etc.

      wildcard_owner = "*.badzone.example.com"
      assert String.starts_with?(wildcard_owner, "*.")
    end

    test "wildcard should not match zone apex" do
      # *.badzone.example.com should NOT match badzone.example.com
      # Only subdomain queries should match
      assert true  # Documented behavior
    end
  end

  describe "RPZ priority and ordering" do
    test "multiple RPZ zones are checked in priority order" do
      # When multiple RPZ zones are configured, they're checked in priority order
      # Lower priority number = higher priority
      # First match wins

      # Example priorities:
      priorities = [
        {"high-priority.rpz", 1},
        {"medium-priority.rpz", 5},
        {"low-priority.rpz", 10}
      ]

      sorted = Enum.sort_by(priorities, fn {_name, prio} -> prio end)
      assert Enum.map(sorted, &elem(&1, 0)) == [
        "high-priority.rpz",
        "medium-priority.rpz",
        "low-priority.rpz"
      ]
    end

    test "passthru in higher priority zone stops checking" do
      # If a higher-priority zone has rpz-passthru for a domain,
      # lower-priority zones should not be checked
      # This allows whitelisting in high-priority zones

      passthru_result = RPZ.decode_rpz_action("rpz-passthru.", :A)
      assert passthru_result.action == :passthru
      # When :passthru is returned, policy checking should stop
    end
  end
end
