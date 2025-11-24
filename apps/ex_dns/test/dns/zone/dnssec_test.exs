defmodule DNS.Zone.DNSSECTest do
  use ExUnit.Case

  alias DNS.ResourceRecordType
  alias DNS.Zone
  alias DNS.Zone.DNSSEC

  describe "DNSSEC zone signing" do
    test "generate_dnskey/2 creates DNSKEY record" do
      dnskey = DNSSEC.generate_dnskey("example.com", algorithm: 8, key_tag: 12345)

      assert dnskey.name.value == "example.com."
      assert to_string(dnskey.type) == "DNSKEY"
      {flags, protocol, algorithm, _public_key} = dnskey.data
      assert algorithm == 8
      assert flags == 256
      assert protocol == 3
    end

    test "generate_ds/3 creates DS record" do
      dnskey = DNSSEC.generate_dnskey("example.com", algorithm: 8, key_tag: 12345)
      ds = DNSSEC.generate_ds("example.com", dnskey, digest_type: 2)

      assert ds.name.value == "example.com."
      assert to_string(ds.type) == "DS"
      {key_tag, algorithm, digest_type, digest} = ds.data
      assert key_tag == DNSSEC.calculate_key_tag(dnskey)
      assert algorithm == 8
      assert digest_type == 2
      assert is_binary(digest)
    end

    test "generate_rrsig/3 creates RRSIG record" do
      record = DNS.Message.Record.new("example.com", :a, :in, 3600, {1, 2, 3, 4})
      records = [record]

      rrsig = DNSSEC.generate_rrsig("example.com", records, algorithm: 8)

      assert rrsig.name.value == "example.com."
      assert to_string(rrsig.type) == "RRSIG"

      {type_covered, algorithm, labels, _original_ttl, _expiration, _inception, _key_tag,
       _signers_name, _signature} = rrsig.data

      assert type_covered == ResourceRecordType.new(:a)
      assert algorithm == 8
      assert labels == 2
    end

    test "generate_nsec/3 creates NSEC record" do
      types = [:a, :aaaa, :mx, :ns]
      nsec = DNSSEC.generate_nsec("example.com", types)

      assert nsec.name.value == "example.com."
      assert to_string(nsec.type) == "NSEC"
      {_next_name, _type_bitmap} = nsec.data
    end

    test "generate_nsec3/3 creates NSEC3 record" do
      types = [:a, :aaaa, :mx, :ns]
      nsec3 = DNSSEC.generate_nsec3("example.com", types, iterations: 1, salt: "abcd")

      assert nsec3.name.value == "example.com."
      assert to_string(nsec3.type) == "NSEC3"
      {algorithm, flags, iterations, salt, _next_hashed, _type_bitmap} = nsec3.data
      assert algorithm == 1
      assert flags == 0
      assert iterations == 1
      assert salt == "abcd"
    end

    test "sign_zone/2 adds DNSSEC records to zone" do
      zone = Zone.new("example.com", :authoritative)

      assert {:ok, signed_zone} = DNSSEC.sign_zone(zone, algorithm: 8)
      assert Keyword.has_key?(signed_zone.options, :dnssec_records)

      dnssec_records = Keyword.get(signed_zone.options, :dnssec_records)
      assert is_list(dnssec_records)
      assert length(dnssec_records) >= 2
    end

    test "validate_zone/1 returns validation result" do
      zone = Zone.new("example.com", :authoritative)
      {:ok, signed_zone} = DNSSEC.sign_zone(zone)

      assert {:ok, _} = DNSSEC.validate_zone(signed_zone)
    end

    test "generate_key_pair/1 returns key pair" do
      assert {:ok, key_pair} = DNSSEC.generate_key_pair(8)
      assert %{public: public, private: private} = key_pair
      assert is_binary(public)
      assert is_binary(private)
    end
  end
end
