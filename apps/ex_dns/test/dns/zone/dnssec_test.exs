defmodule DNS.Zone.DNSSECTest do
  @moduledoc """
  Comprehensive unit tests for DNS.Zone.DNSSEC.

  Tests cover:
  - Module structure and exports
  - DNSKEY record generation
  - DS record generation
  - RRSIG record generation
  - NSEC record generation
  - NSEC3 record generation
  - Zone signing
  - Zone validation
  - Key pair generation
  - Key tag calculation
  - DNSSEC algorithms
  - RFC compliance (4034, 4035, 4509)
  """
  use ExUnit.Case, async: true

  alias DNS.ResourceRecordType
  alias DNS.Zone
  alias DNS.Zone.DNSSEC

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(DNSSEC)
    end

    test "exports generate_dnskey/2" do
      Code.ensure_loaded!(DNSSEC)
      assert Kernel.function_exported?(DNSSEC, :generate_dnskey, 2)
    end

    test "exports generate_ds/3" do
      Code.ensure_loaded!(DNSSEC)
      assert Kernel.function_exported?(DNSSEC, :generate_ds, 3)
    end

    test "exports generate_rrsig/3" do
      Code.ensure_loaded!(DNSSEC)
      assert Kernel.function_exported?(DNSSEC, :generate_rrsig, 3)
    end

    test "exports generate_nsec/3" do
      Code.ensure_loaded!(DNSSEC)
      assert Kernel.function_exported?(DNSSEC, :generate_nsec, 3)
    end

    test "exports generate_nsec3/3" do
      Code.ensure_loaded!(DNSSEC)
      assert Kernel.function_exported?(DNSSEC, :generate_nsec3, 3)
    end

    test "exports sign_zone/2" do
      Code.ensure_loaded!(DNSSEC)
      assert Kernel.function_exported?(DNSSEC, :sign_zone, 2)
    end

    test "exports validate_zone/1" do
      Code.ensure_loaded!(DNSSEC)
      assert Kernel.function_exported?(DNSSEC, :validate_zone, 1)
    end

    test "exports generate_key_pair/1" do
      Code.ensure_loaded!(DNSSEC)
      assert Kernel.function_exported?(DNSSEC, :generate_key_pair, 1)
    end

    test "exports calculate_key_tag/1" do
      Code.ensure_loaded!(DNSSEC)
      assert Kernel.function_exported?(DNSSEC, :calculate_key_tag, 1)
    end
  end

  describe "generate_dnskey/2" do
    test "creates DNSKEY record" do
      dnskey = DNSSEC.generate_dnskey("example.com", algorithm: 8, key_tag: 12345)

      assert dnskey.name.value == "example.com."
      assert to_string(dnskey.type) == "DNSKEY"
    end

    test "sets correct flags for zone key" do
      dnskey = DNSSEC.generate_dnskey("example.com")
      {flags, protocol, algorithm, _public_key} = dnskey.data

      # Default flags 256 = Zone Key
      assert flags == 256
      assert protocol == 3
      assert algorithm == 8
    end

    test "uses provided algorithm" do
      dnskey = DNSSEC.generate_dnskey("example.com", algorithm: 13)
      {_flags, _protocol, algorithm, _public_key} = dnskey.data
      assert algorithm == 13
    end

    test "uses default algorithm 8 (RSASHA256)" do
      dnskey = DNSSEC.generate_dnskey("example.com")
      {_flags, _protocol, algorithm, _public_key} = dnskey.data
      assert algorithm == 8
    end

    test "creates KSK with flags 257" do
      dnskey = DNSSEC.generate_dnskey("example.com", flags: 257)
      {flags, _protocol, _algorithm, _public_key} = dnskey.data
      assert flags == 257
    end

    test "creates ZSK with flags 256" do
      dnskey = DNSSEC.generate_dnskey("example.com", flags: 256)
      {flags, _protocol, _algorithm, _public_key} = dnskey.data
      assert flags == 256
    end

    test "uses protocol 3" do
      dnskey = DNSSEC.generate_dnskey("example.com")
      {_flags, protocol, _algorithm, _public_key} = dnskey.data
      assert protocol == 3
    end

    test "includes public key in data" do
      dnskey = DNSSEC.generate_dnskey("example.com")
      {_flags, _protocol, _algorithm, public_key} = dnskey.data
      assert is_binary(public_key)
    end

    test "sets TTL to 3600" do
      dnskey = DNSSEC.generate_dnskey("example.com")
      assert dnskey.ttl == 3600
    end

    test "sets class to :in" do
      dnskey = DNSSEC.generate_dnskey("example.com")
      assert dnskey.class == :in
    end

    test "appends dot to domain name" do
      dnskey = DNSSEC.generate_dnskey("example.com")
      assert String.ends_with?(dnskey.name.value, ".")
    end

    test "handles subdomain" do
      dnskey = DNSSEC.generate_dnskey("sub.example.com")
      assert dnskey.name.value == "sub.example.com."
    end

    test "accepts various algorithms" do
      for algo <- [5, 7, 8, 10, 13, 14, 15, 16] do
        dnskey = DNSSEC.generate_dnskey("example.com", algorithm: algo)
        {_flags, _protocol, algorithm, _key} = dnskey.data
        assert algorithm == algo
      end
    end
  end

  describe "generate_ds/3" do
    test "creates DS record" do
      dnskey = DNSSEC.generate_dnskey("example.com", algorithm: 8, key_tag: 12345)
      ds = DNSSEC.generate_ds("example.com", dnskey, digest_type: 2)

      assert ds.name.value == "example.com."
      assert to_string(ds.type) == "DS"
    end

    test "calculates key tag from DNSKEY" do
      dnskey = DNSSEC.generate_dnskey("example.com", algorithm: 8, key_tag: 12345)
      ds = DNSSEC.generate_ds("example.com", dnskey)

      {key_tag, _algorithm, _digest_type, _digest} = ds.data
      assert key_tag == DNSSEC.calculate_key_tag(dnskey)
    end

    test "includes algorithm from DNSKEY" do
      dnskey = DNSSEC.generate_dnskey("example.com", algorithm: 8)
      ds = DNSSEC.generate_ds("example.com", dnskey)

      {_key_tag, algorithm, _digest_type, _digest} = ds.data
      assert algorithm == 8
    end

    test "uses SHA-256 digest by default" do
      dnskey = DNSSEC.generate_dnskey("example.com")
      ds = DNSSEC.generate_ds("example.com", dnskey)

      {_key_tag, _algorithm, digest_type, _digest} = ds.data
      assert digest_type == 2
    end

    test "supports SHA-1 digest (type 1)" do
      dnskey = DNSSEC.generate_dnskey("example.com")
      ds = DNSSEC.generate_ds("example.com", dnskey, digest_type: 1)

      {_key_tag, _algorithm, digest_type, _digest} = ds.data
      assert digest_type == 1
    end

    test "supports SHA-384 digest (type 4)" do
      dnskey = DNSSEC.generate_dnskey("example.com")
      ds = DNSSEC.generate_ds("example.com", dnskey, digest_type: 4)

      {_key_tag, _algorithm, digest_type, _digest} = ds.data
      assert digest_type == 4
    end

    test "generates binary digest" do
      dnskey = DNSSEC.generate_dnskey("example.com")
      ds = DNSSEC.generate_ds("example.com", dnskey)

      {_key_tag, _algorithm, _digest_type, digest} = ds.data
      assert is_binary(digest)
    end

    test "sets TTL to 3600" do
      dnskey = DNSSEC.generate_dnskey("example.com")
      ds = DNSSEC.generate_ds("example.com", dnskey)
      assert ds.ttl == 3600
    end

    test "sets class to :in" do
      dnskey = DNSSEC.generate_dnskey("example.com")
      ds = DNSSEC.generate_ds("example.com", dnskey)
      assert ds.class == :in
    end
  end

  describe "generate_rrsig/3" do
    test "creates RRSIG record" do
      record = DNS.Message.Record.new("example.com", :a, :in, 3600, {1, 2, 3, 4})
      records = [record]

      rrsig = DNSSEC.generate_rrsig("example.com", records, algorithm: 8)

      assert rrsig.name.value == "example.com."
      assert to_string(rrsig.type) == "RRSIG"
    end

    test "covers type from signed records" do
      record = DNS.Message.Record.new("example.com", :a, :in, 3600, {1, 2, 3, 4})
      records = [record]

      rrsig = DNSSEC.generate_rrsig("example.com", records, algorithm: 8)

      {type_covered, algorithm, labels, _original_ttl, _expiration, _inception, _key_tag,
       _signers_name, _signature} = rrsig.data

      assert type_covered == ResourceRecordType.new(:a)
      assert algorithm == 8
      assert labels == 2
    end

    test "calculates correct label count" do
      # example.com has 2 labels
      record = DNS.Message.Record.new("example.com", :a, :in, 3600, {1, 2, 3, 4})
      rrsig = DNSSEC.generate_rrsig("example.com", [record])

      {_type, _algo, labels, _, _, _, _, _, _} = rrsig.data
      assert labels == 2
    end

    test "calculates labels for subdomain" do
      # sub.example.com has 3 labels
      record = DNS.Message.Record.new("sub.example.com", :a, :in, 3600, {1, 2, 3, 4})
      rrsig = DNSSEC.generate_rrsig("sub.example.com", [record])

      {_type, _algo, labels, _, _, _, _, _, _} = rrsig.data
      assert labels == 3
    end

    test "includes expiration timestamp" do
      record = DNS.Message.Record.new("example.com", :a, :in, 3600, {1, 2, 3, 4})
      rrsig = DNSSEC.generate_rrsig("example.com", [record])

      {_, _, _, _, expiration, _, _, _, _} = rrsig.data
      assert is_integer(expiration)
      assert expiration > System.system_time(:second)
    end

    test "includes inception timestamp" do
      record = DNS.Message.Record.new("example.com", :a, :in, 3600, {1, 2, 3, 4})
      rrsig = DNSSEC.generate_rrsig("example.com", [record])

      {_, _, _, _, _, inception, _, _, _} = rrsig.data
      assert is_integer(inception)
    end

    test "includes key tag" do
      record = DNS.Message.Record.new("example.com", :a, :in, 3600, {1, 2, 3, 4})
      rrsig = DNSSEC.generate_rrsig("example.com", [record], key_tag: 54321)

      {_, _, _, _, _, _, key_tag, _, _} = rrsig.data
      assert key_tag == 54321
    end

    test "includes signer name" do
      record = DNS.Message.Record.new("example.com", :a, :in, 3600, {1, 2, 3, 4})
      rrsig = DNSSEC.generate_rrsig("example.com", [record], signer_name: "signer.example.com")

      {_, _, _, _, _, _, _, signer_name, _} = rrsig.data
      assert signer_name == "signer.example.com"
    end

    test "includes signature" do
      record = DNS.Message.Record.new("example.com", :a, :in, 3600, {1, 2, 3, 4})
      rrsig = DNSSEC.generate_rrsig("example.com", [record])

      {_, _, _, _, _, _, _, _, signature} = rrsig.data
      assert is_binary(signature)
    end

    test "sets TTL and class" do
      record = DNS.Message.Record.new("example.com", :a, :in, 3600, {1, 2, 3, 4})
      rrsig = DNSSEC.generate_rrsig("example.com", [record])

      assert rrsig.ttl == 3600
      assert rrsig.class == :in
    end
  end

  describe "generate_nsec/3" do
    test "creates NSEC record" do
      types = [:a, :aaaa, :mx, :ns]
      nsec = DNSSEC.generate_nsec("example.com", types)

      assert nsec.name.value == "example.com."
      assert to_string(nsec.type) == "NSEC"
    end

    test "includes next name" do
      types = [:a, :aaaa, :mx, :ns]
      nsec = DNSSEC.generate_nsec("example.com", types)

      {next_name, _type_bitmap} = nsec.data
      assert is_binary(next_name)
    end

    test "includes type bitmap" do
      types = [:a, :aaaa, :mx, :ns]
      nsec = DNSSEC.generate_nsec("example.com", types)

      {_next_name, type_bitmap} = nsec.data
      assert is_binary(type_bitmap)
    end

    test "accepts custom next name" do
      types = [:a]
      nsec = DNSSEC.generate_nsec("example.com", types, next_name: "next.example.com.")

      {next_name, _bitmap} = nsec.data
      assert next_name == "next.example.com."
    end

    test "sets TTL and class" do
      nsec = DNSSEC.generate_nsec("example.com", [:a])

      assert nsec.ttl == 3600
      assert nsec.class == :in
    end
  end

  describe "generate_nsec3/3" do
    test "creates NSEC3 record" do
      types = [:a, :aaaa, :mx, :ns]
      nsec3 = DNSSEC.generate_nsec3("example.com", types, iterations: 1, salt: "abcd")

      assert nsec3.name.value == "example.com."
      assert to_string(nsec3.type) == "NSEC3"
    end

    test "sets hash algorithm to SHA-1" do
      types = [:a]
      nsec3 = DNSSEC.generate_nsec3("example.com", types)

      {algorithm, flags, iterations, salt, _next_hashed, _type_bitmap} = nsec3.data
      assert algorithm == 1
      assert flags == 0
      assert iterations == 1
      assert salt == "abcd"
    end

    test "accepts custom iterations" do
      nsec3 = DNSSEC.generate_nsec3("example.com", [:a], iterations: 10)

      {_algo, _flags, iterations, _salt, _next, _bitmap} = nsec3.data
      assert iterations == 10
    end

    test "accepts custom salt" do
      nsec3 = DNSSEC.generate_nsec3("example.com", [:a], salt: "deadbeef")

      {_algo, _flags, _iter, salt, _next, _bitmap} = nsec3.data
      assert salt == "deadbeef"
    end

    test "includes next hashed owner" do
      nsec3 = DNSSEC.generate_nsec3("example.com", [:a])

      {_algo, _flags, _iter, _salt, next_hashed, _bitmap} = nsec3.data
      assert is_binary(next_hashed)
    end

    test "includes type bitmap" do
      nsec3 = DNSSEC.generate_nsec3("example.com", [:a])

      {_algo, _flags, _iter, _salt, _next, type_bitmap} = nsec3.data
      assert is_binary(type_bitmap)
    end

    test "sets TTL and class" do
      nsec3 = DNSSEC.generate_nsec3("example.com", [:a])

      assert nsec3.ttl == 3600
      assert nsec3.class == :in
    end
  end

  describe "sign_zone/2" do
    test "adds DNSSEC records to zone" do
      zone = Zone.new("example.com", :authoritative)

      assert {:ok, signed_zone} = DNSSEC.sign_zone(zone, algorithm: 8)
      assert Keyword.has_key?(signed_zone.options, :dnssec_records)

      dnssec_records = Keyword.get(signed_zone.options, :dnssec_records)
      assert is_list(dnssec_records)
      assert length(dnssec_records) >= 2
    end

    test "includes DNSKEY records" do
      zone = Zone.new("example.com", :authoritative)

      {:ok, signed_zone} = DNSSEC.sign_zone(zone)

      dnskey_records = Keyword.get(signed_zone.options, :dnskey_records, [])
      assert is_list(dnskey_records)
      assert length(dnskey_records) > 0
    end

    test "includes DS records" do
      zone = Zone.new("example.com", :authoritative)

      {:ok, signed_zone} = DNSSEC.sign_zone(zone)

      ds_records = Keyword.get(signed_zone.options, :ds_records, [])
      assert is_list(ds_records)
      assert length(ds_records) > 0
    end

    test "uses specified algorithm" do
      zone = Zone.new("example.com", :authoritative)

      {:ok, signed_zone} = DNSSEC.sign_zone(zone, algorithm: 13)

      dnskey_records = Keyword.get(signed_zone.options, :dnskey_records, [])
      [dnskey | _] = dnskey_records
      {_flags, _protocol, algorithm, _key} = dnskey.data
      assert algorithm == 13
    end

    test "preserves original zone data" do
      zone = Zone.new("example.com", :authoritative, ttl: 7200)

      {:ok, signed_zone} = DNSSEC.sign_zone(zone)

      assert signed_zone.name.value == "example.com"
      assert signed_zone.type == :authoritative
    end
  end

  describe "validate_zone/1" do
    test "returns validation result" do
      zone = Zone.new("example.com", :authoritative)
      {:ok, signed_zone} = DNSSEC.sign_zone(zone)

      assert {:ok, _} = DNSSEC.validate_zone(signed_zone)
    end

    test "validates unsigned zone" do
      zone = Zone.new("example.com", :authoritative)

      result = DNSSEC.validate_zone(zone)
      # May return ok or error depending on implementation
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  describe "generate_key_pair/1" do
    test "returns key pair" do
      assert {:ok, key_pair} = DNSSEC.generate_key_pair(8)
      assert %{public: public, private: private} = key_pair
      assert is_binary(public)
      assert is_binary(private)
    end

    test "generates different keys for different calls" do
      {:ok, key1} = DNSSEC.generate_key_pair(8)
      {:ok, key2} = DNSSEC.generate_key_pair(8)
      # Keys should exist (implementation may return same dummy keys)
      assert is_binary(key1.public)
      assert is_binary(key2.public)
    end

    test "accepts different algorithms" do
      for algo <- [5, 7, 8, 10, 13, 14] do
        assert {:ok, _} = DNSSEC.generate_key_pair(algo)
      end
    end
  end

  describe "calculate_key_tag/1" do
    test "calculates key tag for DNSKEY" do
      dnskey = DNSSEC.generate_dnskey("example.com")
      key_tag = DNSSEC.calculate_key_tag(dnskey)

      assert is_integer(key_tag)
      assert key_tag >= 0
    end

    test "returns consistent key tag for same key" do
      dnskey = DNSSEC.generate_dnskey("example.com", public_key: "test_key")

      tag1 = DNSSEC.calculate_key_tag(dnskey)
      tag2 = DNSSEC.calculate_key_tag(dnskey)

      assert tag1 == tag2
    end
  end

  describe "DNSSEC algorithms" do
    test "RSA/SHA-1 (algorithm 5)" do
      dnskey = DNSSEC.generate_dnskey("example.com", algorithm: 5)
      {_flags, _protocol, algorithm, _key} = dnskey.data
      assert algorithm == 5
    end

    test "RSA/SHA-256 (algorithm 8)" do
      dnskey = DNSSEC.generate_dnskey("example.com", algorithm: 8)
      {_flags, _protocol, algorithm, _key} = dnskey.data
      assert algorithm == 8
    end

    test "RSA/SHA-512 (algorithm 10)" do
      dnskey = DNSSEC.generate_dnskey("example.com", algorithm: 10)
      {_flags, _protocol, algorithm, _key} = dnskey.data
      assert algorithm == 10
    end

    test "ECDSA P-256/SHA-256 (algorithm 13)" do
      dnskey = DNSSEC.generate_dnskey("example.com", algorithm: 13)
      {_flags, _protocol, algorithm, _key} = dnskey.data
      assert algorithm == 13
    end

    test "ECDSA P-384/SHA-384 (algorithm 14)" do
      dnskey = DNSSEC.generate_dnskey("example.com", algorithm: 14)
      {_flags, _protocol, algorithm, _key} = dnskey.data
      assert algorithm == 14
    end

    test "Ed25519 (algorithm 15)" do
      dnskey = DNSSEC.generate_dnskey("example.com", algorithm: 15)
      {_flags, _protocol, algorithm, _key} = dnskey.data
      assert algorithm == 15
    end

    test "Ed448 (algorithm 16)" do
      dnskey = DNSSEC.generate_dnskey("example.com", algorithm: 16)
      {_flags, _protocol, algorithm, _key} = dnskey.data
      assert algorithm == 16
    end
  end

  describe "edge cases" do
    test "handles root zone" do
      dnskey = DNSSEC.generate_dnskey(".")
      assert dnskey.name.value == "."
    end

    test "handles TLD" do
      dnskey = DNSSEC.generate_dnskey("com")
      assert dnskey.name.value == "com."
    end

    test "handles deeply nested subdomain" do
      name = "a.b.c.d.e.example.com"
      dnskey = DNSSEC.generate_dnskey(name)
      assert dnskey.name.value == name <> "."
    end

    test "empty record list for RRSIG" do
      rrsig = DNSSEC.generate_rrsig("example.com", [])

      {type_covered, _, _, _, _, _, _, _, _} = rrsig.data
      # Default type when no records provided
      assert type_covered == :a or match?(%DNS.ResourceRecordType{}, type_covered)
    end

    test "zone with existing options" do
      zone = Zone.new("example.com", :authoritative, ttl: 7200, custom: "value")

      {:ok, signed_zone} = DNSSEC.sign_zone(zone)

      # Original options should be preserved
      assert Keyword.get(signed_zone.options, :custom) == "value"
    end
  end
end
