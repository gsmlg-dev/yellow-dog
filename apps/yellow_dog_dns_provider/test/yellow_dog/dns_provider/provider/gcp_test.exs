defmodule YellowDog.DnsProvider.Provider.GcpTest do
  use ExUnit.Case, async: true

  alias YellowDog.DnsProvider.Provider.Gcp

  describe "init/1" do
    test "succeeds with project_id" do
      assert {:ok, state} = Gcp.init(%{project_id: "my-project", req: Req.new()})
      assert state.project_id == "my-project"
    end

    test "succeeds with project_id and access_token" do
      assert {:ok, _state} =
               Gcp.init(%{project_id: "my-project", access_token: "ya29.test-token"})
    end

    test "fails without project_id" do
      assert {:error, :missing_project_id} = Gcp.init(%{access_token: "ya29.test"})
    end

    test "fails with empty config" do
      assert {:error, :missing_project_id} = Gcp.init(%{})
    end
  end

  describe "parse_zones/1" do
    test "parses managed zones with trailing dot" do
      zones = [
        %{"name" => "my-zone", "dnsName" => "example.com."},
        %{"name" => "other-zone", "dnsName" => "other.com"}
      ]

      assert [
               %{name: "example.com.", id: "my-zone"},
               %{name: "other.com.", id: "other-zone"}
             ] = Gcp.parse_zones(zones)
    end

    test "parses empty list" do
      assert [] = Gcp.parse_zones([])
    end
  end

  describe "parse_rrsets/1" do
    test "expands rrdatas into individual records" do
      rrsets = [
        %{
          "name" => "www.example.com.",
          "type" => "A",
          "ttl" => 300,
          "rrdatas" => ["1.2.3.4", "5.6.7.8"]
        }
      ]

      records = Gcp.parse_rrsets(rrsets)
      assert length(records) == 2

      assert %{owner: "www.example.com.", type: "A", ttl: 300, rdata: "1.2.3.4"} =
               Enum.at(records, 0)

      assert %{owner: "www.example.com.", type: "A", ttl: 300, rdata: "5.6.7.8"} =
               Enum.at(records, 1)
    end

    test "handles rrset with single rdata" do
      rrsets = [
        %{
          "name" => "example.com.",
          "type" => "MX",
          "ttl" => 600,
          "rrdatas" => ["10 mail.example.com."]
        }
      ]

      assert [%{owner: "example.com.", type: "MX", ttl: 600, rdata: "10 mail.example.com."}] =
               Gcp.parse_rrsets(rrsets)
    end

    test "handles missing rrdatas" do
      rrsets = [%{"name" => "example.com.", "type" => "NS", "ttl" => 300}]
      assert [] = Gcp.parse_rrsets(rrsets)
    end

    test "handles missing ttl" do
      rrsets = [%{"name" => "example.com.", "type" => "A", "rrdatas" => ["1.2.3.4"]}]
      assert [%{ttl: 0}] = Gcp.parse_rrsets(rrsets)
    end

    test "ensures trailing dot on owner" do
      rrsets = [%{"name" => "example.com", "type" => "A", "ttl" => 60, "rrdatas" => ["1.1.1.1"]}]
      assert [%{owner: "example.com."}] = Gcp.parse_rrsets(rrsets)
    end
  end

  describe "group_by_rrset/1" do
    test "groups records by name, type, and ttl" do
      records = [
        %{owner: "www.example.com.", type: "A", ttl: 300, rdata: "1.2.3.4"},
        %{owner: "www.example.com.", type: "A", ttl: 300, rdata: "5.6.7.8"}
      ]

      result = Gcp.group_by_rrset(records)
      assert length(result) == 1

      [rrset] = result
      assert rrset["name"] == "www.example.com."
      assert rrset["type"] == "A"
      assert rrset["ttl"] == 300
      assert Enum.sort(rrset["rrdatas"]) == ["1.2.3.4", "5.6.7.8"]
    end

    test "separates different types into distinct rrsets" do
      records = [
        %{owner: "example.com.", type: "A", ttl: 300, rdata: "1.2.3.4"},
        %{owner: "example.com.", type: "AAAA", ttl: 300, rdata: "::1"}
      ]

      result = Gcp.group_by_rrset(records)
      assert length(result) == 2
    end

    test "handles empty list" do
      assert [] = Gcp.group_by_rrset([])
    end

    test "ensures trailing dot on name" do
      records = [%{owner: "example.com", type: "A", ttl: 60, rdata: "1.1.1.1"}]

      [rrset] = Gcp.group_by_rrset(records)
      assert rrset["name"] == "example.com."
    end
  end

  describe "parse_soa_serial/1" do
    test "extracts serial from SOA rdata" do
      rdata = "ns1.example.com. admin.example.com. 2024010100 3600 900 1209600 86400"
      assert 2_024_010_100 = Gcp.parse_soa_serial(rdata)
    end

    test "returns 0 for incomplete SOA rdata" do
      assert 0 = Gcp.parse_soa_serial("ns1.example.com. admin.example.com.")
    end
  end
end
