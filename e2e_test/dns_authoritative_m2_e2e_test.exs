defmodule E2ETest.DnsAuthoritativeM2E2ETest do
  use ExUnit.Case, async: false

  alias E2ETest.ServiceHelper
  alias YellowDog.Dns.ManagedSnapshot
  alias YellowDog.Sync.DnsManifest

  @moduletag :e2e
  @moduletag :dns

  setup do
    {:ok, ctx} = ServiceHelper.start_dns_system(listen: {127, 0, 0, 1})
    dir = Path.join(System.tmp_dir!(), "dns-m2-wire-#{System.unique_integer([:positive])}")

    on_exit(fn ->
      ServiceHelper.stop_dns_system(ctx)
      File.rm_rf!(dir)
    end)

    assert {:ok, _} = ManagedSnapshot.install(manifest(), dir)
    {:ok, ctx}
  end

  test "v1 RRsets and CNAME chains answer authoritatively over UDP and TCP", ctx do
    cases = [
      {"example.test.", "SOA", "2026092901"},
      {"example.test.", "NS", "ns1.example.test."},
      {"ns1.example.test.", "A", "192.0.2.53"},
      {"v6.example.test.", "AAAA", "2001:db8::53"},
      {"mail.example.test.", "MX", "10 v6.example.test."},
      {"text.example.test.", "TXT", ~s("first" "second with space")},
      {"alias.example.test.", "A", "192.0.2.54"}
    ]

    for transport <- [:udp, :tcp], {name, type, expected} <- cases do
      output = dig(ctx, transport, name, type)
      context = "#{transport} #{name}: #{output}"
      assert output =~ "status: NOERROR", context
      assert authoritative?(output), context
      refute recursive_available?(output), context
      assert output =~ expected, context
    end

    for transport <- [:udp, :tcp] do
      output = dig(ctx, transport, "external-alias.example.test.", "A")
      assert output =~ "external.example.invalid."
      assert output =~ "CNAME"
      refute Regex.match?(~r/\sIN\s+A\s/, output)
      assert authoritative?(output)
      refute recursive_available?(output)

      outside = dig(ctx, transport, "outside.example.invalid.", "A")
      assert outside =~ "status: REFUSED" or outside =~ "status: SERVFAIL"
      assert outside =~ "ANSWER: 0"
      refute recursive_available?(outside)
    end
  end

  test "wildcards, empty nonterminals and negative answers follow the closest encloser", ctx do
    for transport <- [:udp, :tcp] do
      wildcard = dig(ctx, transport, "wild.example.test.", "A")
      assert wildcard =~ "192.0.2.99"
      assert authoritative?(wildcard)

      ent = dig(ctx, transport, "branch.example.test.", "A")
      assert ent =~ "status: NOERROR"
      refute ent =~ "192.0.2.99"
      assert ent =~ "SOA"
      assert authoritative?(ent)

      blocked_wildcard = dig(ctx, transport, "missing.branch.example.test.", "A")
      assert blocked_wildcard =~ "status: NXDOMAIN"
      refute blocked_wildcard =~ "192.0.2.99"
      assert blocked_wildcard =~ "SOA"
      assert authoritative?(blocked_wildcard)

      nodata = dig(ctx, transport, "ns1.example.test.", "AAAA")
      assert nodata =~ "status: NOERROR"
      assert nodata =~ "SOA"
      assert authoritative?(nodata)
    end
  end

  test "large UDP replies truncate and TCP returns every TXT record", ctx do
    udp = dig(ctx, :udp, "big.example.test.", "TXT", ["+noedns", "+ignore"])
    assert Regex.match?(~r/flags:.*\btc\b/, udp), udp
    assert authoritative?(udp)

    edns = dig(ctx, :udp, "big.example.test.", "TXT", ["+bufsize=4096", "+ignore"])
    assert edns =~ "EDNS: version: 0", edns
    assert edns =~ "udp: 1232", edns
    assert Regex.match?(~r/flags:.*\btc\b/, edns), edns

    tcp = dig(ctx, :tcp, "big.example.test.", "TXT")
    refute Regex.match?(~r/flags:.*\btc\b/, tcp)
    assert authoritative?(tcp)
    assert length(Regex.scan(~r/\sIN\s+TXT\s/, tcp)) == 8
  end

  test "TCP frames complete large answers and rejects undersized messages", ctx do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, ctx.tcp_port, [:binary, active: false])
    on_exit(fn -> :gen_tcp.close(socket) end)

    query =
      <<0x12, 0x34, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0, 3, "big", 7, "example", 4, "test", 0, 0,
        16, 0, 1>>

    assert :ok = :gen_tcp.send(socket, <<byte_size(query)::16>>)
    assert :ok = :gen_tcp.send(socket, query)
    assert {:ok, <<length::16>>} = :gen_tcp.recv(socket, 2, 2_000)
    assert length > 512
    assert {:ok, response} = :gen_tcp.recv(socket, length, 2_000)
    assert byte_size(response) == length
    assert <<0x12, 0x34, flags::16, _qdcount::16, 8::16, _rest::binary>> = response
    assert Bitwise.band(flags, 0x0400) != 0
    assert Bitwise.band(flags, 0x0200) == 0

    {:ok, invalid_socket} =
      :gen_tcp.connect({127, 0, 0, 1}, ctx.tcp_port, [:binary, active: false])

    on_exit(fn -> :gen_tcp.close(invalid_socket) end)
    assert :ok = :gen_tcp.send(invalid_socket, <<11::16, 0::size(11 * 8)>>)
    assert {:error, :closed} = :gen_tcp.recv(invalid_socket, 2, 2_000)
  end

  defp dig(ctx, transport, name, type, extra_args \\ []) do
    port = if transport == :tcp, do: ctx.tcp_port, else: ctx.port

    args =
      [
        "@127.0.0.1",
        "-p",
        to_string(port),
        "+time=2",
        "+tries=1",
        "+noall",
        "+comments",
        "+answer",
        "+authority"
      ] ++ extra_args ++ [name, type]

    args = if transport == :tcp, do: ["+tcp" | args], else: args
    {output, 0} = System.cmd("dig", args, stderr_to_stdout: true)
    output
  end

  defp authoritative?(output), do: Regex.match?(~r/flags:.*\baa\b/, output)
  defp recursive_available?(output), do: Regex.match?(~r/flags:.*\bra\b/, output)

  defp manifest do
    apex = "example.test."

    soa = %{
      "mname" => "ns1.example.test.",
      "rname" => "hostmaster.example.test.",
      "serial" => 2_026_092_901,
      "refresh" => 3600,
      "retry" => 600,
      "expire" => 86_400,
      "minimum" => 300
    }

    rrsets = [
      rrset(apex, "SOA", [soa]),
      rrset(apex, "NS", ["ns1.example.test."]),
      rrset("ns1.example.test.", "A", ["192.0.2.53"]),
      rrset("v6.example.test.", "AAAA", ["2001:db8::53"]),
      rrset("mail.example.test.", "MX", [%{"preference" => 10, "exchange" => "v6.example.test."}]),
      rrset("text.example.test.", "TXT", [["first", "second with space"]]),
      rrset("target.example.test.", "A", ["192.0.2.54"]),
      rrset("alias.example.test.", "CNAME", ["target.example.test."]),
      rrset("external-alias.example.test.", "CNAME", ["external.example.invalid."]),
      rrset("*.example.test.", "A", ["192.0.2.99"]),
      rrset("leaf.branch.example.test.", "A", ["192.0.2.44"]),
      rrset(
        "big.example.test.",
        "TXT",
        for(i <- 1..8, do: [String.duplicate("x", 175) <> to_string(i)])
      )
    ]

    zone = %{"zone_id" => "m2-zone", "apex" => apex, "version" => 1, "rrsets" => rrsets}
    {:ok, digest} = DnsManifest.zone_digest(zone)

    %{
      "schema_version" => 1,
      "server_id" => "m2-server",
      "generation" => 1,
      "zones" => [Map.put(zone, "digest", digest)]
    }
  end

  defp rrset(owner, type, records),
    do: %{"owner" => owner, "type" => type, "ttl" => 300, "records" => records}
end
