defmodule DNS.Zone.RootHint do
  @moduledoc """
  DNS Root Hint

  Root Servers

  The authoritative name servers that serve the DNS root zone, commonly known as the “root servers”, are a network of hundreds of servers in many countries around the world. They are configured in the DNS root zone as 13 named authorities, as follows.

  List of Root Servers

  Hostname | IP Addresses | Operator
  a.root-servers.net | 198.41.0.4, 2001:503:ba3e::2:30 | Verisign, Inc.
  b.root-servers.net | 170.247.170.2, 2801:1b8:10::b | University of Southern California, Information Sciences Institute
  c.root-servers.net | 192.33.4.12, 2001:500:2::c | Cogent Communications
  d.root-servers.net | 199.7.91.13, 2001:500:2d::d | University of Maryland
  e.root-servers.net | 192.203.230.10, 2001:500:a8::e | NASA (Ames Research Center)
  f.root-servers.net | 192.5.5.241, 2001:500:2f::f | Internet Systems Consortium, Inc.
  g.root-servers.net | 192.112.36.4, 2001:500:12::d0d | US Department of Defense (NIC)
  h.root-servers.net | 198.97.190.53, 2001:500:1::53 | US Army (Research Lab)
  i.root-servers.net | 192.36.148.17, 2001:7fe::53 | Netnod
  j.root-servers.net | 192.58.128.30, 2001:503:c27::2:30 | Verisign, Inc.
  k.root-servers.net | 193.0.14.129, 2001:7fd::1 | RIPE NCC
  l.root-servers.net | 199.7.83.42, 2001:500:9f::42 | ICANN
  m.root-servers.net | 202.12.27.33, 2001:dc3::35 | WIDE Project

  """
  alias DNS.ResourceRecordType, as: RRType
  alias DNS.Message.Domain

  @links [
    root_hints: "https://www.internic.net/domain/named.root",
    root_zone: "https://www.internic.net/domain/root.zone",
    root_trust_anchor: [
      url: "https://data.iana.org/root-anchors/",
      icannbundle: "icannbundle.pem",
      p7s: "root-anchors.p7s",
      xml: "root-anchors.xml",
      checksum: "checksums-sha256.txt"
    ],
    top_level_domains: "https://data.iana.org/TLD/tlds-alpha-by-domain.txt"
  ]

  def links(), do: @links

  def data_dir, do: Path.join([:code.priv_dir(:ex_dns), "data"])

  def root_hints() do
    root_hints_text()
    |> String.split("\n")
    |> Enum.filter(&(!String.starts_with?(&1, ";")))
    |> Enum.filter(&(String.length(&1) > 0))
    |> Enum.map(fn line ->
      type_map = %{"A" => :a, "AAAA" => :aaaa, "NS" => :ns}
      [name, ttl, type, data] = line |> String.split(~r[\s+])
      rtype = Map.get(type_map, type)

      rdata =
        case rtype do
          :a ->
            {:ok, addr} = :inet.parse_ipv4_address(String.to_charlist(data))
            addr

          :aaaa ->
            {:ok, addr} = :inet.parse_ipv6_address(String.to_charlist(data))
            addr

          :ns ->
            Domain.new(data)
        end

      [name: name, ttl: String.to_integer(ttl), type: RRType.new(rtype), rdata: rdata]
    end)
  end

  def root_hints_text, do: File.read!(Path.join(data_dir(), "named.root"))

  def nameservers() do
    root_hints()
    |> Enum.filter(fn record -> record[:type] == RRType.new(:ns) end)
    |> Enum.map(fn record -> record[:rdata] end)
    |> Enum.into(%{}, fn name ->
      glue = root_hints() |> Enum.filter(fn record -> record[:name] == to_string(name) end)

      glue_a = glue |> Enum.filter(fn record -> record[:type] == RRType.new(:a) end)
      glue_aaaa = glue |> Enum.filter(fn record -> record[:type] == RRType.new(:aaaa) end)

      {to_string(name),
       %{
         name: name,
         ipv4: glue_a |> Enum.map(fn record -> record[:rdata] end),
         ipv6: glue_aaaa |> Enum.map(fn record -> record[:rdata] end)
       }}
    end)
  end
end
