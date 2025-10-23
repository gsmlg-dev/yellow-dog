defmodule DNS.Zone.ValidatorTest do
  use ExUnit.Case

  alias DNS.Zone
  alias DNS.Zone.Validator
  alias DNS.Zone.Manager
  alias DNS.Message.Record

  setup do
    Manager.init()
    :ok
  end

  describe "Zone validation" do
    test "validate_zone returns ok for valid zone" do
      zone_name = "example.com"

      # Create valid zone
      zone = Zone.new(zone_name, :authoritative)

      soa_record =
        Record.new(
          zone_name,
          :soa,
          :in,
          3600,
          {"ns1.example.com", "admin.example.com", 1, 3600, 1800, 604_800, 300}
        )

      ns_record = Record.new(zone_name, :ns, :in, 3600, "ns1.example.com")

      options = Keyword.put(zone.options, :soa_records, [soa_record])
      options = Keyword.put(options, :ns_records, [ns_record])
      zone = %{zone | options: options}

      assert {:ok, result} = Validator.validate_zone(zone)
      assert result.zone_name == zone_name
      assert result.status == :valid
    end

    test "validate_zone returns error for invalid zone" do
      zone = Zone.new("", :authoritative)

      assert {:error, result} = Validator.validate_zone(zone)
      assert result.status == :invalid
      assert Enum.any?(result.errors, &String.contains?(&1, "Zone name is empty"))
    end
  end

  describe "Zone structure validation" do
    test "validate_zone_structure detects empty zone name" do
      zone = Zone.new("", :authoritative)
      {errors, _warnings} = Validator.validate_zone_structure(zone)
      assert Enum.any?(errors, &String.contains?(&1, "Zone name is empty"))
    end

    test "validate_zone_structure detects invalid zone type" do
      zone = Zone.new("example.com", :invalid_type)
      {errors, _warnings} = Validator.validate_zone_structure(zone)
      assert Enum.any?(errors, &String.contains?(&1, "Invalid zone type"))
    end
  end

  describe "SOA record validation" do
    test "validate_soa_record detects invalid serial" do
      zone = Zone.new("example.com", :authoritative)

      soa_record =
        Record.new(
          "example.com",
          :soa,
          :in,
          3600,
          {"ns1.example.com", "admin.example.com", 0, 3600, 1800, 604_800, 300}
        )

      options = Keyword.put(zone.options, :soa_records, [soa_record])
      zone = %{zone | options: options}

      {errors, _warnings} = Validator.validate_soa_record(zone)
      assert Enum.any?(errors, &String.contains?(&1, "Invalid SOA serial number"))
    end

    test "validate_soa_record detects refresh < retry" do
      zone = Zone.new("example.com", :authoritative)

      soa_record =
        Record.new(
          "example.com",
          :soa,
          :in,
          3600,
          {"ns1.example.com", "admin.example.com", 1, 1800, 3600, 604_800, 300}
        )

      options = Keyword.put(zone.options, :soa_records, [soa_record])
      zone = %{zone | options: options}

      {_errors, warnings} = Validator.validate_soa_record(zone)

      assert Enum.any?(
               warnings,
               &String.contains?(&1, "refresh interval should be greater than retry")
             )
    end

    test "validate_soa_record detects multiple SOA" do
      zone = Zone.new("example.com", :authoritative)

      soa1 =
        Record.new(
          "example.com",
          :soa,
          :in,
          3600,
          {"ns1.example.com", "admin.example.com", 1, 3600, 1800, 604_800, 300}
        )

      soa2 =
        Record.new(
          "example.com",
          :soa,
          :in,
          3600,
          {"ns2.example.com", "admin.example.com", 2, 3600, 1800, 604_800, 300}
        )

      options = Keyword.put(zone.options, :soa_records, [soa1, soa2])
      zone = %{zone | options: options}

      {_errors, warnings} = Validator.validate_soa_record(zone)
      assert Enum.any?(warnings, &String.contains?(&1, "Multiple SOA records found"))
    end
  end

  describe "NS record validation" do
    test "validate_ns_records detects missing A/AAAA for NS" do
      zone = Zone.new("example.com", :authoritative)

      soa_record =
        Record.new(
          "example.com",
          :soa,
          :in,
          3600,
          {"ns1.example.com", "admin.example.com", 1, 3600, 1800, 604_800, 300}
        )

      ns_record = Record.new("example.com", :ns, :in, 3600, "ns1.example.com")

      options = Keyword.put(zone.options, :soa_records, [soa_record])
      options = Keyword.put(options, :ns_records, [ns_record])
      zone = %{zone | options: options}

      {_errors, warnings} = Validator.validate_ns_records(zone)

      assert Enum.any?(
               warnings,
               &String.contains?(
                 &1,
                 "NS record ns1.example.com has no corresponding A/AAAA record"
               )
             )
    end

    test "validate_ns_records passes with A record for NS" do
      zone = Zone.new("example.com", :authoritative)

      soa_record =
        Record.new(
          "example.com",
          :soa,
          :in,
          3600,
          {"ns1.example.com", "admin.example.com", 1, 3600, 1800, 604_800, 300}
        )

      ns_record = Record.new("example.com", :ns, :in, 3600, "ns1.example.com")
      a_record = Record.new("ns1.example.com", :a, :in, 3600, {192, 168, 1, 1})

      options = Keyword.put(zone.options, :soa_records, [soa_record])
      options = Keyword.put(options, :ns_records, [ns_record])
      options = Keyword.put(options, :a_records, [a_record])
      zone = %{zone | options: options}

      {_errors, warnings} = Validator.validate_ns_records(zone)
      refute Enum.any?(warnings, &String.contains?(&1, "NS record"))
    end
  end

  describe "Record consistency validation" do
    test "validate_record_consistency detects CNAME conflicts" do
      zone = Zone.new("example.com", :authoritative)
      cname_record = Record.new("www.example.com", :cname, :in, 3600, "example.com")
      a_record = Record.new("www.example.com", :a, :in, 3600, {192, 168, 1, 1})

      options = Keyword.put(zone.options, :cname_records, [cname_record])
      options = Keyword.put(options, :a_records, [a_record])
      zone = %{zone | options: options}

      {errors, _warnings} = Validator.validate_record_consistency(zone)
      assert Enum.any?(errors, &String.contains?(&1, "CNAME record conflicts"))
    end
  end

  describe "DNSSEC validation" do
    test "validate_dnssec_records detects missing DNSKEY" do
      zone = Zone.new("example.com", :authoritative)

      soa_record =
        Record.new(
          "example.com",
          :soa,
          :in,
          3600,
          {"ns1.example.com", "admin.example.com", 1, 3600, 1800, 604_800, 300}
        )

      options = Keyword.put(zone.options, :soa_records, [soa_record])
      options = Keyword.put(options, :dnssec_records, [])
      options = Keyword.put(options, :dnskey_records, [])
      zone = %{zone | options: options}

      {errors, _warnings} = Validator.validate_dnssec_records(zone)

      assert Enum.any?(
               errors,
               &String.contains?(&1, "DNSSEC enabled but no DNSKEY records found")
             )
    end
  end

  describe "TTL validation" do
    test "validate_ttl_values detects negative TTL" do
      zone = Zone.new("example.com", :authoritative)
      a_record = Record.new("www.example.com", :a, :in, -1, {192, 168, 1, 1})

      options = Keyword.put(zone.options, :a_records, [a_record])
      zone = %{zone | options: options}

      {errors, _warnings} = Validator.validate_ttl_values(zone)
      assert Enum.any?(errors, &String.contains?(&1, "Negative TTL value"))
    end

    test "validate_ttl_values detects very short TTL" do
      zone = Zone.new("example.com", :authoritative)
      a_record = Record.new("www.example.com", :a, :in, 10, {192, 168, 1, 1})

      options = Keyword.put(zone.options, :a_records, [a_record])
      zone = %{zone | options: options}

      {_errors, warnings} = Validator.validate_ttl_values(zone)
      assert Enum.any?(warnings, &String.contains?(&1, "Very short TTL"))
    end
  end

  describe "Zone diagnostics" do
    test "generate_diagnostics returns comprehensive report" do
      zone = Zone.new("example.com", :authoritative)

      soa_record =
        Record.new(
          "example.com",
          :soa,
          :in,
          3600,
          {"ns1.example.com", "admin.example.com", 1, 3600, 1800, 604_800, 300}
        )

      ns_record = Record.new("example.com", :ns, :in, 3600, "ns1.example.com")
      a_record = Record.new("www.example.com", :a, :in, 3600, {192, 168, 1, 1})

      options = Keyword.put(zone.options, :soa_records, [soa_record])
      options = Keyword.put(options, :ns_records, [ns_record])
      options = Keyword.put(options, :a_records, [a_record])
      zone = %{zone | options: options}

      diagnostics = Validator.generate_diagnostics(zone)

      assert diagnostics.zone_name == "example.com"
      assert diagnostics.zone_type == :authoritative
      assert is_map(diagnostics.statistics)
      assert is_list(diagnostics.recommendations)
      assert is_map(diagnostics.security_assessment)
      assert is_map(diagnostics.performance_metrics)
    end
  end

  describe "Zone statistics" do
    test "generate_statistics returns correct counts" do
      zone = Zone.new("example.com", :authoritative)

      soa_record =
        Record.new(
          "example.com",
          :soa,
          :in,
          3600,
          {"ns1.example.com", "admin.example.com", 1, 3600, 1800, 604_800, 300}
        )

      ns_record = Record.new("example.com", :ns, :in, 3600, "ns1.example.com")
      a_record = Record.new("www.example.com", :a, :in, 3600, {192, 168, 1, 1})

      options = Keyword.put(zone.options, :soa_records, [soa_record])
      options = Keyword.put(options, :ns_records, [ns_record])
      options = Keyword.put(options, :a_records, [a_record])
      zone = %{zone | options: options}

      stats = Validator.generate_statistics(zone)

      assert stats.total_records == 3
      assert stats.unique_names == 2
      assert stats.dnssec_enabled == false
    end
  end

  describe "Security assessment" do
    test "generate_security_assessment for non-DNSSEC zone" do
      zone = Zone.new("example.com", :authoritative)

      assessment = Validator.generate_security_assessment(zone)

      assert assessment.dnssec_enabled == false
      assert assessment.dnssec_valid == false
      assert assessment.transfer_restrictions == false
      assert is_map(assessment.record_validation)
      assert is_integer(assessment.overall_score)
    end

    test "generate_security_assessment for DNSSEC zone" do
      zone = Zone.new("example.com", :authoritative)

      soa_record =
        Record.new(
          "example.com",
          :soa,
          :in,
          3600,
          {"ns1.example.com", "admin.example.com", 1, 3600, 1800, 604_800, 300}
        )

      dnskey_record =
        Record.new("example.com", :dnskey, :in, 3600, {256, 3, 8, "dummy_public_key"})

      options = Keyword.put(zone.options, :soa_records, [soa_record])
      options = Keyword.put(options, :dnskey_records, [dnskey_record])
      zone = %{zone | options: options}

      assessment = Validator.generate_security_assessment(zone)

      assert assessment.dnssec_enabled == true
      assert assessment.dnssec_valid == true
    end
  end

  describe "Performance metrics" do
    test "generate_performance_metrics returns correct data" do
      zone = Zone.new("example.com", :authoritative)

      metrics = Validator.generate_performance_metrics(zone)

      assert is_integer(metrics.record_count)
      assert is_float(metrics.cache_efficiency)
      assert is_binary(metrics.query_response_time)
      assert is_integer(metrics.zone_size)
    end
  end
end
