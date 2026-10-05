Code.require_file(
  Path.expand("../../apps/yellow_dog_management/test/support/domain_fixtures.ex", __DIR__)
)

ExUnit.start(seed: 0)

defmodule YellowDog.ManagementBindParserGate do
  use ExUnit.Case, async: true

  alias DNS.Zone.{FileParser, Parser}
  alias YellowDog.Management.DomainFixtures
  alias YellowDog.ManagementUI.DnsRecordExports

  # TODO(upstream): gsmlg-dev/ex_dns#5
  describe "lossless AST parsing required for Management BIND import" do
    test "accepts the actual Management BIND export without rewriting SOA" do
      source = DnsRecordExports.bind(DomainFixtures.zone())
      assert {:ok, parsed} = Parser.parse(source)
      assert Enum.map(parsed.records, & &1.type) == ["SOA", "NS", "A"]
      [soa | _records] = parsed.records
      assert soa.ttl == 300
      assert soa.rdata.serial == 1
      assert soa.rdata.minimum == 300
    end

    test "inherits the preceding owner without losing the explicit TTL" do
      assert {:ok, parsed} = Parser.parse(inherited_owner_source())
      [first, second] = parsed.records
      assert first.name == second.name
      assert second.ttl == 600
      assert second.rdata == "192.0.2.2"
    end

    test "retains SOA fields for the already supported parenthesized syntax" do
      assert {:ok, parsed} = Parser.parse(parenthesized_soa_source())
      [soa] = parsed.records
      assert soa.type == "SOA"
      assert soa.ttl == 300
      assert soa.rdata.serial == 1
      assert soa.rdata.refresh == 3600
      assert soa.rdata.retry == 600
      assert soa.rdata.expire == 86_400
      assert soa.rdata.minimum == 300
    end
  end

  # TODO(upstream): gsmlg-dev/ex_dns#6
  describe "strict alternative parsing required for Management BIND import" do
    test "rejects unknown record types rather than reporting empty success" do
      source = "$ORIGIN example.test.\n$TTL 300\nwww 300 IN WAT 192.0.2.1\n"
      assert {:error, _reason} = FileParser.parse(source)
    end

    test "retains directive errors instead of validating a partial result" do
      source = "$ORIGIN example.test.\n$TTL nonsense\nwww 300 IN A 192.0.2.1\n"
      assert {:error, _reason} = FileParser.parse(source)
    end

    test "does not shift parenthesized SOA numbers" do
      assert {:ok, parsed} = FileParser.parse(parenthesized_soa_source())
      assert parsed.soa.serial == 1
      assert parsed.soa.refresh == 3600
      assert parsed.soa.retry == 600
      assert parsed.soa.expire == 86_400
      assert parsed.soa.minimum == 300
    end

    test "does not invent an owner from an inherited record's TTL" do
      assert {:ok, parsed} = FileParser.parse(inherited_owner_source())
      assert length(parsed.records) == 2
      assert Enum.all?(parsed.records, &(&1.name == "www.example.test"))
      assert Enum.sort(Enum.map(parsed.records, & &1.ttl)) == [300, 600]
    end
  end

  defp inherited_owner_source do
    "$ORIGIN example.test.\n$TTL 300\n" <>
      "www 300 IN A 192.0.2.1\n    600 IN A 192.0.2.2\n"
  end

  defp parenthesized_soa_source do
    "$ORIGIN example.test.\n$TTL 300\n" <>
      "@ 300 IN SOA ns1.example.test. hostmaster.example.test. ( 1 3600 600 86400 300 )\n"
  end
end
