defmodule YellowDog.DnsProvider.Provider.AwsTest do
  use ExUnit.Case, async: true

  alias YellowDog.DnsProvider.Provider.Aws

  describe "init/1" do
    test "succeeds with access_key_id and secret_access_key" do
      assert {:ok, state} =
               Aws.init(%{access_key_id: "AKIATEST", secret_access_key: "secret123"})

      assert %{req: %Req.Request{}, access_key_id: "AKIATEST"} = state
    end

    test "fails without credentials" do
      assert {:error, :missing_credentials} = Aws.init(%{})
    end

    test "fails with only access_key_id" do
      assert {:error, :missing_credentials} = Aws.init(%{access_key_id: "AKIATEST"})
    end

    test "fails with only secret_access_key" do
      assert {:error, :missing_credentials} = Aws.init(%{secret_access_key: "secret"})
    end

    test "accepts injected :req for testing" do
      req = Req.new(base_url: "http://test")

      assert {:ok, %{req: ^req}} =
               Aws.init(%{access_key_id: "AK", secret_access_key: "SK", req: req})
    end
  end

  describe "parse_hosted_zones_xml/1" do
    test "parses single hosted zone" do
      xml = """
      <ListHostedZonesResponse>
        <HostedZones>
          <HostedZone>
            <Id>/hostedzone/Z1234567890</Id>
            <Name>example.com.</Name>
            <CallerReference>ref-1</CallerReference>
          </HostedZone>
        </HostedZones>
      </ListHostedZonesResponse>
      """

      assert [%{name: "example.com.", id: "Z1234567890"}] =
               Aws.parse_hosted_zones_xml(xml)
    end

    test "parses multiple hosted zones" do
      xml = """
      <ListHostedZonesResponse>
        <HostedZones>
          <HostedZone>
            <Id>/hostedzone/Z111</Id>
            <Name>alpha.com.</Name>
            <CallerReference>ref-1</CallerReference>
          </HostedZone>
          <HostedZone>
            <Id>/hostedzone/Z222</Id>
            <Name>beta.org</Name>
            <CallerReference>ref-2</CallerReference>
          </HostedZone>
        </HostedZones>
      </ListHostedZonesResponse>
      """

      result = Aws.parse_hosted_zones_xml(xml)
      assert length(result) == 2
      assert Enum.at(result, 0) == %{name: "alpha.com.", id: "Z111"}
      assert Enum.at(result, 1) == %{name: "beta.org.", id: "Z222"}
    end

    test "returns empty list for no zones" do
      xml = """
      <ListHostedZonesResponse>
        <HostedZones/>
      </ListHostedZonesResponse>
      """

      assert [] = Aws.parse_hosted_zones_xml(xml)
    end
  end

  describe "parse_rrsets_xml/1" do
    test "parses A records" do
      xml = """
      <ListResourceRecordSetsResponse>
        <ResourceRecordSets>
          <ResourceRecordSet>
            <Name>example.com.</Name>
            <Type>A</Type>
            <TTL>300</TTL>
            <ResourceRecords>
              <ResourceRecord><Value>1.2.3.4</Value></ResourceRecord>
              <ResourceRecord><Value>5.6.7.8</Value></ResourceRecord>
            </ResourceRecords>
          </ResourceRecordSet>
        </ResourceRecordSets>
      </ListResourceRecordSetsResponse>
      """

      result = Aws.parse_rrsets_xml(xml)
      assert length(result) == 2

      assert Enum.at(result, 0) == %{
               owner: "example.com.",
               type: "A",
               ttl: 300,
               rdata: "1.2.3.4"
             }

      assert Enum.at(result, 1) == %{
               owner: "example.com.",
               type: "A",
               ttl: 300,
               rdata: "5.6.7.8"
             }
    end

    test "parses SOA record" do
      xml = """
      <ListResourceRecordSetsResponse>
        <ResourceRecordSets>
          <ResourceRecordSet>
            <Name>example.com.</Name>
            <Type>SOA</Type>
            <TTL>900</TTL>
            <ResourceRecords>
              <ResourceRecord><Value>ns1.example.com. admin.example.com. 2024010100 3600 900 1209600 86400</Value></ResourceRecord>
            </ResourceRecords>
          </ResourceRecordSet>
        </ResourceRecordSets>
      </ListResourceRecordSetsResponse>
      """

      assert [%{type: "SOA", rdata: rdata}] = Aws.parse_rrsets_xml(xml)
      assert String.contains?(rdata, "2024010100")
    end

    test "parses MX records" do
      xml = """
      <ListResourceRecordSetsResponse>
        <ResourceRecordSets>
          <ResourceRecordSet>
            <Name>example.com.</Name>
            <Type>MX</Type>
            <TTL>3600</TTL>
            <ResourceRecords>
              <ResourceRecord><Value>10 mail.example.com.</Value></ResourceRecord>
            </ResourceRecords>
          </ResourceRecordSet>
        </ResourceRecordSets>
      </ListResourceRecordSetsResponse>
      """

      assert [%{type: "MX", rdata: "10 mail.example.com."}] = Aws.parse_rrsets_xml(xml)
    end

    test "returns empty list for empty rrsets" do
      xml = """
      <ListResourceRecordSetsResponse>
        <ResourceRecordSets/>
      </ListResourceRecordSetsResponse>
      """

      assert [] = Aws.parse_rrsets_xml(xml)
    end
  end

  describe "build_change_batch_xml/1" do
    test "builds XML with CREATE actions for additions" do
      changeset = %{
        additions: [
          %{owner: "test.example.com.", type: "A", ttl: 300, rdata: "1.2.3.4"}
        ],
        deletions: []
      }

      xml = Aws.build_change_batch_xml(changeset)
      assert String.contains?(xml, "<Action>CREATE</Action>")
      assert String.contains?(xml, "<Name>test.example.com.</Name>")
      assert String.contains?(xml, "<Type>A</Type>")
      assert String.contains?(xml, "<TTL>300</TTL>")
      assert String.contains?(xml, "<Value>1.2.3.4</Value>")
    end

    test "builds XML with DELETE actions for deletions" do
      changeset = %{
        additions: [],
        deletions: [
          %{owner: "old.example.com.", type: "CNAME", ttl: 600, rdata: "target.example.com."}
        ]
      }

      xml = Aws.build_change_batch_xml(changeset)
      assert String.contains?(xml, "<Action>DELETE</Action>")
      assert String.contains?(xml, "<Name>old.example.com.</Name>")
      assert String.contains?(xml, "<Type>CNAME</Type>")
    end

    test "groups records by owner, type, and ttl into single RRSet" do
      changeset = %{
        additions: [
          %{owner: "multi.example.com.", type: "A", ttl: 300, rdata: "1.1.1.1"},
          %{owner: "multi.example.com.", type: "A", ttl: 300, rdata: "2.2.2.2"}
        ],
        deletions: []
      }

      xml = Aws.build_change_batch_xml(changeset)

      # Should have exactly one Change element with two ResourceRecord entries
      assert length(Regex.scan(~r/<Action>CREATE<\/Action>/, xml)) == 1
      assert length(Regex.scan(~r/<Value>/, xml)) == 2
    end

    test "DELETE changes come before CREATE changes" do
      changeset = %{
        additions: [%{owner: "new.example.com.", type: "A", ttl: 300, rdata: "1.1.1.1"}],
        deletions: [%{owner: "old.example.com.", type: "A", ttl: 300, rdata: "9.9.9.9"}]
      }

      xml = Aws.build_change_batch_xml(changeset)
      delete_pos = :binary.match(xml, "DELETE") |> elem(0)
      create_pos = :binary.match(xml, "CREATE") |> elem(0)
      assert delete_pos < create_pos
    end

    test "wraps in ChangeResourceRecordSetsRequest" do
      changeset = %{additions: [], deletions: []}
      xml = Aws.build_change_batch_xml(changeset)
      assert String.contains?(xml, "<ChangeResourceRecordSetsRequest")
      assert String.contains?(xml, "</ChangeResourceRecordSetsRequest>")
      assert String.contains?(xml, "<ChangeBatch>")
    end

    test "escapes special XML characters in values" do
      changeset = %{
        additions: [
          %{owner: "txt.example.com.", type: "TXT", ttl: 300, rdata: "v=spf1 include:test&co.com"}
        ],
        deletions: []
      }

      xml = Aws.build_change_batch_xml(changeset)
      assert String.contains?(xml, "test&amp;co.com")
    end
  end

  describe "parse_soa_serial/1" do
    test "extracts serial from SOA rdata" do
      rdata = "ns1.example.com. admin.example.com. 2024010100 3600 900 1209600 86400"
      assert 2_024_010_100 = Aws.parse_soa_serial(rdata)
    end

    test "returns 0 for malformed SOA" do
      assert 0 = Aws.parse_soa_serial("short")
    end
  end
end
