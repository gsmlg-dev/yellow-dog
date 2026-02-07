defmodule YellowDog.Console.DnsFilterFunctionsTest do
  @moduledoc """
  Unit tests for public filter and helper functions across DNS LiveViews.
  These functions are exposed as `def` for testability.
  """
  use ExUnit.Case, async: true

  alias YellowDog.Console.DnsLive.ZoneLive.Index, as: ZoneLive
  alias YellowDog.Console.DnsLive.RrLive.Index, as: RrLive
  alias YellowDog.Console.DnsLive.ViewLive.Index, as: ViewLive
  alias YellowDog.Console.DnsLive.AclLive

  # ============================================================================
  # ZoneLive: filtered_zones/3, unique_zone_types/1, zone_type_badge/1, zone_type_label/1
  # ============================================================================

  describe "ZoneLive.filtered_zones/3" do
    @zones [
      %{name: "example.com", type: :auth},
      %{name: "forward.io", type: :forward},
      %{name: "stub.net", type: :stub},
      %{name: "cache.org", type: :cache}
    ]

    test "returns all zones with empty filter and 'all' type" do
      assert length(ZoneLive.filtered_zones(@zones, "", "all")) == 4
    end

    test "filters by name substring" do
      result = ZoneLive.filtered_zones(@zones, "example", "all")
      assert length(result) == 1
      assert hd(result).name == "example.com"
    end

    test "filters are case-insensitive" do
      result = ZoneLive.filtered_zones(@zones, "FORWARD", "all")
      assert length(result) == 1
      assert hd(result).name == "forward.io"
    end

    test "filters by type string" do
      result = ZoneLive.filtered_zones(@zones, "", "auth")
      assert length(result) == 1
      assert hd(result).type == :auth
    end

    test "combines name and type filters" do
      result = ZoneLive.filtered_zones(@zones, "example", "auth")
      assert length(result) == 1
    end

    test "returns empty for non-matching filter" do
      result = ZoneLive.filtered_zones(@zones, "nonexistent", "all")
      assert result == []
    end

    test "unknown type returns all zones" do
      result = ZoneLive.filtered_zones(@zones, "", "bogus")
      assert length(result) == 4
    end

    test "handles empty zones list" do
      assert ZoneLive.filtered_zones([], "test", "all") == []
    end
  end

  describe "ZoneLive.unique_zone_types/1" do
    test "returns unique types sorted" do
      zones = [%{type: :forward}, %{type: :auth}, %{type: :forward}]
      types = ZoneLive.unique_zone_types(zones)
      assert types == [:auth, :forward]
    end

    test "handles empty list" do
      assert ZoneLive.unique_zone_types([]) == []
    end
  end

  describe "ZoneLive.zone_type_badge/1" do
    test "auth returns primary" do
      assert ZoneLive.zone_type_badge(:auth) == "primary"
    end

    test "forward returns secondary" do
      assert ZoneLive.zone_type_badge(:forward) == "secondary"
    end

    test "stub returns accent" do
      assert ZoneLive.zone_type_badge(:stub) == "accent"
    end

    test "cache returns info" do
      assert ZoneLive.zone_type_badge(:cache) == "info"
    end

    test "unknown returns ghost" do
      assert ZoneLive.zone_type_badge(:something_else) == "ghost"
    end
  end

  describe "ZoneLive.zone_type_label/1" do
    test "auth returns Authoritative" do
      assert ZoneLive.zone_type_label(:auth) == "Authoritative"
    end

    test "forward returns Forward" do
      assert ZoneLive.zone_type_label(:forward) == "Forward"
    end

    test "stub returns Stub" do
      assert ZoneLive.zone_type_label(:stub) == "Stub"
    end

    test "cache returns Cache" do
      assert ZoneLive.zone_type_label(:cache) == "Cache"
    end

    test "unknown returns Unknown" do
      assert ZoneLive.zone_type_label(:other) == "Unknown"
    end
  end

  # ============================================================================
  # RrLive: filtered_records/3, unique_record_types/1, record_type_badge/1, parse_bulk_preview/2
  # ============================================================================

  describe "RrLive.filtered_records/3" do
    @records [
      %{name: "www", type: :a, data: "1.2.3.4", ttl: 300},
      %{name: "mail", type: :mx, data: "10 mx.example.com", ttl: 3600},
      %{name: "@", type: :ns, data: "ns1.example.com", ttl: 86400},
      %{name: "www", type: :aaaa, data: "::1", ttl: 300}
    ]

    test "returns all records with empty filter and 'all' type" do
      assert length(RrLive.filtered_records(@records, "", "all")) == 4
    end

    test "filters by name substring" do
      result = RrLive.filtered_records(@records, "www", "all")
      assert length(result) == 2
    end

    test "filters by type string" do
      result = RrLive.filtered_records(@records, "", "mx")
      assert length(result) == 1
      assert hd(result).type == :mx
    end

    test "combines name and type filters" do
      result = RrLive.filtered_records(@records, "www", "a")
      assert length(result) == 1
      assert hd(result).data == "1.2.3.4"
    end

    test "returns empty for non-matching name" do
      assert RrLive.filtered_records(@records, "nonexistent", "all") == []
    end

    test "unknown type string returns all records" do
      result = RrLive.filtered_records(@records, "", "bogus")
      assert length(result) == 4
    end

    test "handles empty records list" do
      assert RrLive.filtered_records([], "test", "all") == []
    end

    test "nil filter returns all records" do
      assert length(RrLive.filtered_records(@records, nil, "all")) == 4
    end
  end

  describe "RrLive.unique_record_types/1" do
    test "returns unique types" do
      records = [%{type: :a}, %{type: :mx}, %{type: :a}, %{type: :ns}]
      types = RrLive.unique_record_types(records)
      assert :a in types
      assert :mx in types
      assert :ns in types
      assert length(types) == 3
    end

    test "handles empty list" do
      assert RrLive.unique_record_types([]) == []
    end
  end

  describe "RrLive.record_type_badge/1" do
    test "a returns primary" do
      assert RrLive.record_type_badge(:a) == "primary"
    end

    test "aaaa returns primary" do
      assert RrLive.record_type_badge(:aaaa) == "primary"
    end

    test "cname returns secondary" do
      assert RrLive.record_type_badge(:cname) == "secondary"
    end

    test "ns returns accent" do
      assert RrLive.record_type_badge(:ns) == "accent"
    end

    test "mx returns info" do
      assert RrLive.record_type_badge(:mx) == "info"
    end

    test "txt returns warning" do
      assert RrLive.record_type_badge(:txt) == "warning"
    end

    test "soa returns success" do
      assert RrLive.record_type_badge(:soa) == "success"
    end

    test "srv returns info" do
      assert RrLive.record_type_badge(:srv) == "info"
    end

    test "ptr returns accent" do
      assert RrLive.record_type_badge(:ptr) == "accent"
    end

    test "unknown returns ghost" do
      assert RrLive.record_type_badge(:spf) == "ghost"
    end
  end

  describe "RrLive.parse_bulk_preview/2" do
    test "returns nil for empty string" do
      assert RrLive.parse_bulk_preview("", "example.com") == nil
    end

    test "returns nil for nil input" do
      assert RrLive.parse_bulk_preview(nil, "example.com") == nil
    end

    test "parses valid A record" do
      result = RrLive.parse_bulk_preview("www 300 IN A 1.2.3.4", "example.com")
      assert result != nil
    end

    test "returns error for invalid record" do
      result = RrLive.parse_bulk_preview("not a valid record !!!", "example.com")
      # Returns %{status: :error, message: ...} for parse failures
      assert is_map(result)
      assert result.status == :error
      assert is_binary(result.message)
    end
  end

  # ============================================================================
  # ViewLive: filtered_views/3
  # ============================================================================

  describe "ViewLive.filtered_views/3" do
    @views [
      %{name: "default", priority: 100, zones: [%{}], enabled: true},
      %{name: "internal", priority: 50, zones: [], enabled: false},
      %{name: "external", priority: 200, zones: [%{}, %{}], enabled: true}
    ]

    test "returns all views with empty filter and 'all' status" do
      assert length(ViewLive.filtered_views(@views, "", "all")) == 3
    end

    test "filters by name substring" do
      result = ViewLive.filtered_views(@views, "intern", "all")
      assert length(result) == 1
      assert hd(result).name == "internal"
    end

    test "filters by active status" do
      result = ViewLive.filtered_views(@views, "", "active")
      assert length(result) == 2
      assert Enum.all?(result, & &1.enabled)
    end

    test "filters by disabled status" do
      result = ViewLive.filtered_views(@views, "", "disabled")
      assert length(result) == 1
      assert hd(result).name == "internal"
    end

    test "combines name and status filters" do
      result = ViewLive.filtered_views(@views, "default", "active")
      assert length(result) == 1
    end

    test "returns empty for non-matching filter" do
      assert ViewLive.filtered_views(@views, "nonexistent", "all") == []
    end

    test "handles empty views list" do
      assert ViewLive.filtered_views([], "test", "all") == []
    end
  end

  # ============================================================================
  # AclLive: filtered_named_acls/3, unique_acl_types/1
  # ============================================================================

  describe "AclLive.filtered_named_acls/3" do
    @acls [
      %{name: "trusted", description: "Trusted clients", entries: []},
      %{name: "blocked", description: "Blocked IPs", entries: []}
    ]

    test "returns all with empty filter" do
      assert length(AclLive.filtered_named_acls(@acls, "", "all")) == 2
    end

    test "filters by name" do
      result = AclLive.filtered_named_acls(@acls, "trust", "all")
      assert length(result) == 1
      assert hd(result).name == "trusted"
    end

    test "filters by description" do
      result = AclLive.filtered_named_acls(@acls, "Blocked IPs", "all")
      assert length(result) == 1
      assert hd(result).name == "blocked"
    end

    test "case-insensitive filtering" do
      result = AclLive.filtered_named_acls(@acls, "TRUSTED", "all")
      assert length(result) == 1
    end

    test "returns empty for non-matching filter" do
      assert AclLive.filtered_named_acls(@acls, "nope", "all") == []
    end

    test "handles empty list" do
      assert AclLive.filtered_named_acls([], "test", "all") == []
    end
  end

  describe "AclLive.unique_acl_types/1" do
    test "returns unique acl types from views" do
      views = [%{acl_type: "allow"}, %{acl_type: "deny"}, %{acl_type: "allow"}]
      types = AclLive.unique_acl_types(views)
      assert length(types) == 2
      assert "allow" in types
      assert "deny" in types
    end

    test "handles empty list" do
      assert AclLive.unique_acl_types([]) == []
    end
  end
end
