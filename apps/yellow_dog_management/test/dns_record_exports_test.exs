defmodule YellowDog.ManagementUI.DnsRecordExportsTest do
  use ExUnit.Case, async: true

  alias YellowDog.Management.DomainFixtures
  alias YellowDog.ManagementUI.DnsRecordExports

  test "CSV contains SOA, NS and A typed RDATA rather than JSON or placeholders" do
    zone = DomainFixtures.zone()

    assert DnsRecordExports.csv(zone["records"]) ==
             "Name,Type,TTL,Data\r\n" <>
               "example.test.,SOA,300,ns1.example.test. hostmaster.example.test. 1 3600 600 86400 300\r\n" <>
               "example.test.,NS,300,ns1.example.test.\r\n" <>
               "ns1.example.test.,A,300,192.0.2.10\r\n"

    assert DnsRecordExports.csv([]) == "Name,Type,TTL,Data\r\n"
  end

  test "CSV escapes separators, quotes and line breaks" do
    record = %{
      "name" => "comma,quote\"line\n",
      "type" => "A",
      "ttl" => 300,
      "data" => %{"address" => "192.0.2.10"}
    }

    assert DnsRecordExports.csv([record]) ==
             "Name,Type,TTL,Data\r\n\"comma,quote\"\"line\n\",A,300,192.0.2.10\r\n"
  end

  test "CSV neutralizes spreadsheet formula and control prefixes without losing values" do
    for value <- ["=1", "+1", "-1", "@SUM(1)", "  =1", "\tplain", "\rplain", "\nplain"] do
      record = %{"name" => value, "type" => "NS", "ttl" => 0, "data" => %{"host" => value}}
      exported = DnsRecordExports.csv([record])
      assert exported =~ "'" <> value
      refute exported =~ "," <> value <> "\r\n"
    end
  end

  test "BIND uses the full Zone with explicit TTL, IN class and typed RDATA" do
    assert DnsRecordExports.bind(DomainFixtures.zone()) ==
             "$ORIGIN example.test.\n" <>
               "example.test. 300 IN SOA ns1.example.test. hostmaster.example.test. 1 3600 600 86400 300\n" <>
               "example.test. 300 IN NS ns1.example.test.\n" <>
               "ns1.example.test. 300 IN A 192.0.2.10\n"
  end

  test "BIND preserves record order, each TTL and SOA mailbox case" do
    zone = DomainFixtures.zone()

    records =
      Enum.map(zone["records"], fn record ->
        case record["type"] do
          "SOA" -> put_in(record, ["data", "rname"], "Hostmaster.example.test.")
          "A" -> Map.put(record, "ttl", 0)
          "NS" -> Map.put(record, "ttl", 86400)
        end
      end)

    output = DnsRecordExports.bind(Map.put(zone, "records", records))
    assert output =~ "SOA ns1.example.test. Hostmaster.example.test."
    assert output =~ "example.test. 86400 IN NS ns1.example.test."
    assert output =~ "ns1.example.test. 0 IN A 192.0.2.10"
  end
end
