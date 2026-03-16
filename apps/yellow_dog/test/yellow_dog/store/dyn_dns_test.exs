defmodule YellowDog.Store.DynDnsTest do
  use ExUnit.Case

  alias YellowDog.Store.DynDns

  @moduletag :store_integration

  @tag :skip
  test "put and get forward record" do
    fqdn = "test.example.com."

    record = %{
      type: :a,
      rdata: {192, 168, 1, 100},
      dns_ttl: 300,
      source: :dhcp,
      source_ref: "dhcp:lease:v4:aa:bb:cc:dd:ee:ff"
    }

    assert :ok = DynDns.put(fqdn, record)
    {:ok, result} = DynDns.get(fqdn)

    assert result.type == :a
    assert result.rdata == {192, 168, 1, 100}
    assert result.source == :dhcp
    assert is_integer(result.created_at)
    assert is_integer(result.updated_at)
  end

  @tag :skip
  test "put_ptr and get_ptr reverse record" do
    arpa = "100.1.168.192.in-addr.arpa"
    fqdn = "test.example.com."

    assert :ok = DynDns.put_ptr(arpa, fqdn)
    {:ok, result} = DynDns.get_ptr(arpa)

    assert result.type == :ptr
    assert result.rdata == fqdn
  end

  @tag :skip
  test "put with TTL option" do
    fqdn = "ttl-test.example.com."
    record = %{type: :a, rdata: {10, 0, 0, 1}, dns_ttl: 60, source: :api, source_ref: "manual"}

    assert :ok = DynDns.put(fqdn, record, ttl: 60)
  end

  @tag :skip
  test "delete removes forward and reverse records" do
    fqdn = "delete-test.example.com."
    record = %{type: :a, rdata: "192.168.1.50", dns_ttl: 300, source: :dhcp, source_ref: "ref"}

    DynDns.put(fqdn, record)
    assert :ok = DynDns.delete(fqdn)
    assert {:error, :not_found} = DynDns.get(fqdn)
  end

  @tag :skip
  test "delete of non-existent record succeeds" do
    assert :ok = DynDns.delete("nonexistent.example.com.")
  end

  @tag :skip
  test "list_by_source filters by source" do
    DynDns.put("dhcp1.example.com.", %{
      type: :a,
      rdata: {10, 0, 0, 1},
      dns_ttl: 300,
      source: :dhcp,
      source_ref: "ref1"
    })

    DynDns.put("api1.example.com.", %{
      type: :a,
      rdata: {10, 0, 0, 2},
      dns_ttl: 300,
      source: :api,
      source_ref: "ref2"
    })

    {:ok, dhcp_records} = DynDns.list_by_source(:dhcp)
    assert Enum.all?(dhcp_records, &(&1.source == :dhcp))
  end

  @tag :skip
  test "get returns :not_found for unknown FQDN" do
    assert {:error, :not_found} = DynDns.get("unknown.example.com.")
  end
end
