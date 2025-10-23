defmodule DNS.Zone.FileParserTest do
  use ExUnit.Case

  describe "parse/1" do
    test "parses basic zone file" do
      zone_content = """
      $ORIGIN example.com.
      $TTL 3600
      @       IN  SOA ns1.example.com. admin.example.com. 2024010101 3600 1800 604800 86400
      @       IN  NS  ns1.example.com.
      @       IN  NS  ns2.example.com.
      ns1     IN  A   192.0.2.1
      ns2     IN  A   192.0.2.2
      www     IN  A   192.0.2.100
      """

      assert {:ok, zone} = DNS.Zone.FileParser.parse(zone_content)
      assert zone.origin == "example.com"
      assert zone.ttl == 3600
      assert length(zone.records) >= 5
    end

    test "parses HTTPS record with ALPN" do
      zone_content = """
      $ORIGIN discord.com.
      $TTL 300
      @       IN  SOA ns1.discord.com. admin.discord.com. 2024010101 3600 1800 604800 86400
      @       IN  NS  ns1.discord.com.
      @       IN  HTTPS 1 . alpn="h3,h2" ipv4hint=162.159.128.233
      """

      assert {:ok, zone} = DNS.Zone.FileParser.parse(zone_content)
      https_records = Enum.filter(zone.records, fn r -> r.type == :https end)
      assert length(https_records) == 1
      [record] = https_records
      assert record.name == "discord.com"
      assert record.ttl == 300

      assert [%{priority: 1, target: ".", params: "alpn=\"h3,h2\" ipv4hint=162.159.128.233"}] =
               record.data
    end

    test "handles DNSSEC records" do
      zone_content = """
      $ORIGIN example.com.
      $TTL 3600
      @       IN  SOA ns1.example.com. admin.example.com. 2024010101 3600 1800 604800 86400
      @       IN  NS  ns1.example.com.
      example.com. IN DNSKEY 256 3 8 AwEAAc3...
      example.com. IN DS 12345 8 2 49FD46E6...
      """

      assert {:ok, zone} = DNS.Zone.FileParser.parse(zone_content)
      dnskey_records = Enum.filter(zone.records, fn r -> r.type == :dnskey end)
      ds_records = Enum.filter(zone.records, fn r -> r.type == :ds end)
      assert length(dnskey_records) == 1
      assert length(ds_records) == 1
    end
  end

  describe "parse root zone file" do
    test "parse root zone file" do
      file_path = Path.expand("data/root.zone", :code.priv_dir(:ex_dns))
      zone_content = File.read!(file_path)
      assert {:ok, zone} = DNS.Zone.FileParser.parse(zone_content)
      assert %{} = zone
    end
  end
end
