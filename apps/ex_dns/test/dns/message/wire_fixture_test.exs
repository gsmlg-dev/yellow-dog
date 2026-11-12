defmodule DNS.Message.WireFixtureTest do
  @moduledoc """
  Decodes real responses captured from the internet on 2026-11-13.

  The fixtures are hex dumps of raw UDP payloads under `test/fixtures/wire/`:

  - `root_org_referral` - a.root-servers.net, `example.org A` (referral to `org`)
  - `com_example_referral` - a.gtld-servers.net, `example.com A` (referral)
  - `cf_www_amazon_a` - 1.1.1.1, `www.amazon.com A` (CNAME chain)
  - `root_longname_com_referral` - a.root-servers.net, a 200-octet name under
    `com`; the glue names compress to offsets >= 256 (pointer first byte 0xC1)
  """
  use ExUnit.Case, async: true

  alias DNS.Message

  @fixtures Path.expand("../../fixtures/wire", __DIR__)

  defp fixture(name) do
    @fixtures
    |> Path.join(name <> ".hex")
    |> File.read!()
    |> String.trim()
    |> Base.decode16!(case: :lower)
  end

  defp names(records), do: Enum.map(records, &to_string(&1.name))
  defp rdata(records), do: Enum.map(records, &to_string(&1.data))

  test "root referral for org" do
    msg = Message.from_iodata(fixture("root_org_referral"))

    assert length(msg.nslist) == 6
    assert Enum.uniq(names(msg.nslist)) == ["org."]

    assert "a2.org.afilias-nst.info." in rdata(msg.nslist)
    assert "v0n0.pir-ns.org." in rdata(msg.nslist)
    assert length(msg.arlist) == 13
    assert "v0n0.pir-ns.org." in names(msg.arlist)
  end

  test "com referral for example.com" do
    msg = Message.from_iodata(fixture("com_example_referral"))

    assert names(msg.nslist) == ["example.com.", "example.com."]

    assert rdata(msg.nslist) == ["hera.ns.cloudflare.com.", "elliott.ns.cloudflare.com."]

    assert length(msg.arlist) == 13
    assert "elliott.ns.cloudflare.com." in names(msg.arlist)
  end

  test "1.1.1.1 CNAME chain for www.amazon.com" do
    msg = Message.from_iodata(fixture("cf_www_amazon_a"))

    # Wire order: CNAME, CNAME, then the final A.
    assert names(msg.anlist) == [
             "www.amazon.com.",
             "tp.47cf2c8c9-frontier.amazon.com.",
             "cf.47cf2c8c9-frontier.amazon.com."
           ]

    assert Enum.map(msg.anlist, &to_string(&1.type)) == ["CNAME", "CNAME", "A"]

    cnames =
      for r <- msg.anlist,
          to_string(r.type) == "CNAME",
          into: %{},
          do: {to_string(r.name), to_string(r.data)}

    assert cnames == %{
             "www.amazon.com." => "tp.47cf2c8c9-frontier.amazon.com.",
             "tp.47cf2c8c9-frontier.amazon.com." => "cf.47cf2c8c9-frontier.amazon.com."
           }
  end

  test "large referral with compression pointers to offsets >= 256" do
    wire = fixture("root_longname_com_referral")
    assert byte_size(wire) > 256
    assert :binary.match(wire, <<0xC1>>) != :nomatch

    msg = Message.from_iodata(wire)

    assert length(msg.nslist) == 13
    assert Enum.uniq(names(msg.nslist)) == ["com."]
    assert hd(rdata(msg.nslist)) == "l.gtld-servers.net."

    glue = msg.arlist |> names() |> Enum.reject(&(&1 == "."))
    assert length(glue) == 26
    assert Enum.all?(glue, &String.ends_with?(&1, ".gtld-servers.net."))
    assert MapSet.new(glue) == MapSet.new(rdata(msg.nslist))
  end
end
