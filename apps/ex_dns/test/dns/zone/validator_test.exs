defmodule DNS.Zone.ValidatorTest do
  use ExUnit.Case, async: false

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

    test "validate_zone includes summary counts" do
      zone = Zone.new("test.com", :authoritative)

      assert {:ok, result} = Validator.validate_zone(zone)
      assert result.summary.total_errors == 0
      assert is_integer(result.summary.total_warnings)
      assert is_integer(result.summary.total_records)
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

    test "validate_zone_structure accepts valid zone types" do
      for type <- [:authoritative, :stub, :forward, :cache] do
        zone = Zone.new("example.com", type)
        {errors, _warnings} = Validator.validate_zone_structure(zone)
        refute Enum.any?(errors, &String.contains?(&1, "Invalid zone type"))
      end
    end

    test "validate_zone_structure warns about missing NS records" do
      zone = Zone.new("example.com", :authoritative)
      {_errors, warnings} = Validator.validate_zone_structure(zone)
      assert Enum.any?(warnings, &String.contains?(&1, "No NS records found"))
    end

    test "validate_zone_structure no warning when NS records present" do
      zone = Zone.new("example.com", :authoritative)
      ns_record = Record.new("example.com", :ns, :in, 3600, "ns1.example.com")
      options = Keyword.put(zone.options, :ns_records, [ns_record])
      zone = %{zone | options: options}

      {_errors, warnings} = Validator.validate_zone_structure(zone)
      refute Enum.any?(warnings, &String.contains?(&1, "No NS records found"))
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

    test "validate_soa_record detects serial > max" do
      zone = Zone.new("example.com", :authoritative)

      soa_record =
        Record.new(
          "example.com",
          :soa,
          :in,
          3600,
          {"ns1.example.com", "admin.example.com", 4_294_967_296, 3600, 1800, 604_800, 300}
        )

      options = Keyword.put(zone.options, :soa_records, [soa_record])
      zone = %{zone | options: options}

      {errors, _warnings} = Validator.validate_soa_record(zone)
      assert Enum.any?(errors, &String.contains?(&1, "Invalid SOA serial number"))
    end

    test "validate_soa_record detects invalid refresh" do
      zone = Zone.new("example.com", :authoritative)

      soa_record =
        Record.new(
          "example.com",
          :soa,
          :in,
          3600,
          {"ns1.example.com", "admin.example.com", 1, 0, 1800, 604_800, 300}
        )

      options = Keyword.put(zone.options, :soa_records, [soa_record])
      zone = %{zone | options: options}

      {errors, _warnings} = Validator.validate_soa_record(zone)
      assert Enum.any?(errors, &String.contains?(&1, "Invalid SOA refresh interval"))
    end

    test "validate_soa_record detects invalid retry" do
      zone = Zone.new("example.com", :authoritative)

      soa_record =
        Record.new(
          "example.com",
          :soa,
          :in,
          3600,
          {"ns1.example.com", "admin.example.com", 1, 3600, 0, 604_800, 300}
        )

      options = Keyword.put(zone.options, :soa_records, [soa_record])
      zone = %{zone | options: options}

      {errors, _warnings} = Validator.validate_soa_record(zone)
      assert Enum.any?(errors, &String.contains?(&1, "Invalid SOA retry interval"))
    end

    test "validate_soa_record detects invalid expire" do
      zone = Zone.new("example.com", :authoritative)

      soa_record =
        Record.new(
          "example.com",
          :soa,
          :in,
          3600,
          {"ns1.example.com", "admin.example.com", 1, 3600, 1800, 0, 300}
        )

      options = Keyword.put(zone.options, :soa_records, [soa_record])
      zone = %{zone | options: options}

      {errors, _warnings} = Validator.validate_soa_record(zone)
      assert Enum.any?(errors, &String.contains?(&1, "Invalid SOA expire interval"))
    end

    test "validate_soa_record detects negative minimum" do
      zone = Zone.new("example.com", :authoritative)

      soa_record =
        Record.new(
          "example.com",
          :soa,
          :in,
          3600,
          {"ns1.example.com", "admin.example.com", 1, 3600, 1800, 604_800, -1}
        )

      options = Keyword.put(zone.options, :soa_records, [soa_record])
      zone = %{zone | options: options}

      {errors, _warnings} = Validator.validate_soa_record(zone)
      assert Enum.any?(errors, &String.contains?(&1, "Invalid SOA minimum TTL"))
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

    test "validate_soa_record detects expire < refresh" do
      zone = Zone.new("example.com", :authoritative)

      soa_record =
        Record.new(
          "example.com",
          :soa,
          :in,
          3600,
          {"ns1.example.com", "admin.example.com", 1, 7200, 1800, 3600, 300}
        )

      options = Keyword.put(zone.options, :soa_records, [soa_record])
      zone = %{zone | options: options}

      {_errors, warnings} = Validator.validate_soa_record(zone)

      assert Enum.any?(
               warnings,
               &String.contains?(&1, "expire interval should be greater than refresh")
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

    test "validate_soa_record passes for valid SOA" do
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
      zone = %{zone | options: options}

      {errors, _warnings} = Validator.validate_soa_record(zone)
      assert errors == []
    end

    test "validate_soa_record with no SOA records" do
      zone = Zone.new("example.com", :authoritative)
      {errors, warnings} = Validator.validate_soa_record(zone)
      assert errors == []
      assert warnings == []
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

    test "validate_ns_records passes with AAAA record for NS" do
      zone = Zone.new("example.com", :authoritative)

      ns_record = Record.new("example.com", :ns, :in, 3600, "ns1.example.com")

      aaaa_record =
        Record.new("ns1.example.com", :aaaa, :in, 3600, {0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1})

      options = Keyword.put(zone.options, :ns_records, [ns_record])
      options = Keyword.put(options, :aaaa_records, [aaaa_record])
      zone = %{zone | options: options}

      {_errors, warnings} = Validator.validate_ns_records(zone)
      refute Enum.any?(warnings, &String.contains?(&1, "NS record"))
    end

    test "validate_ns_records with no NS records" do
      zone = Zone.new("example.com", :authoritative)
      {errors, warnings} = Validator.validate_ns_records(zone)
      assert errors == []
      assert warnings == []
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

    test "validate_record_consistency allows CNAME without conflicts" do
      zone = Zone.new("example.com", :authoritative)
      cname_record = Record.new("alias.example.com", :cname, :in, 3600, "example.com")
      a_record = Record.new("www.example.com", :a, :in, 3600, {192, 168, 1, 1})

      options = Keyword.put(zone.options, :cname_records, [cname_record])
      options = Keyword.put(options, :a_records, [a_record])
      zone = %{zone | options: options}

      {errors, _warnings} = Validator.validate_record_consistency(zone)
      refute Enum.any?(errors, &String.contains?(&1, "CNAME record conflicts"))
    end

    test "validate_record_consistency with no records" do
      zone = Zone.new("example.com", :authoritative)
      {errors, warnings} = Validator.validate_record_consistency(zone)
      assert errors == []
      assert warnings == []
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

    test "validate_dnssec_records skips when no DNSSEC" do
      zone = Zone.new("example.com", :authoritative)
      {errors, warnings} = Validator.validate_dnssec_records(zone)
      assert errors == []
      assert warnings == []
    end

    test "validate_dnssec_records detects missing DS for authoritative" do
      zone = Zone.new("example.com", :authoritative)

      dnskey_record =
        Record.new("example.com", :dnskey, :in, 3600, {256, 3, 8, "dummy_key"})

      options = Keyword.put(zone.options, :dnskey_records, [dnskey_record])
      options = Keyword.put(options, :ds_records, [])
      zone = %{zone | options: options}

      {_errors, warnings} = Validator.validate_dnssec_records(zone)

      assert Enum.any?(
               warnings,
               &String.contains?(&1, "DNSSEC enabled but no DS records found")
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

    test "validate_ttl_values does not warn about short TTL for SOA" do
      zone = Zone.new("example.com", :authoritative)

      soa_record =
        Record.new(
          "example.com",
          :soa,
          :in,
          10,
          {"ns1.example.com", "admin.example.com", 1, 3600, 1800, 604_800, 300}
        )

      options = Keyword.put(zone.options, :soa_records, [soa_record])
      zone = %{zone | options: options}

      {_errors, warnings} = Validator.validate_ttl_values(zone)
      refute Enum.any?(warnings, &String.contains?(&1, "Very short TTL"))
    end

    test "validate_ttl_values detects very long TTL" do
      zone = Zone.new("example.com", :authoritative)
      a_record = Record.new("www.example.com", :a, :in, 700_000, {192, 168, 1, 1})

      options = Keyword.put(zone.options, :a_records, [a_record])
      zone = %{zone | options: options}

      {_errors, warnings} = Validator.validate_ttl_values(zone)
      assert Enum.any?(warnings, &String.contains?(&1, "Very long TTL"))
    end

    test "validate_ttl_values detects TTL exceeds maximum" do
      zone = Zone.new("example.com", :authoritative)
      a_record = Record.new("www.example.com", :a, :in, 2_147_483_648, {192, 168, 1, 1})

      options = Keyword.put(zone.options, :a_records, [a_record])
      zone = %{zone | options: options}

      {_errors, warnings} = Validator.validate_ttl_values(zone)
      assert Enum.any?(warnings, &String.contains?(&1, "TTL value exceeds maximum"))
    end

    test "validate_ttl_values passes for normal TTL" do
      zone = Zone.new("example.com", :authoritative)
      a_record = Record.new("www.example.com", :a, :in, 3600, {192, 168, 1, 1})

      options = Keyword.put(zone.options, :a_records, [a_record])
      zone = %{zone | options: options}

      {errors, warnings} = Validator.validate_ttl_values(zone)
      assert errors == []
      assert warnings == []
    end

    test "validate_ttl_values with no records" do
      zone = Zone.new("example.com", :authoritative)
      {errors, warnings} = Validator.validate_ttl_values(zone)
      assert errors == []
      assert warnings == []
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

    test "generate_statistics groups records by normalized type" do
      zone = Zone.new("example.com", :authoritative)

      a_record1 = Record.new("www.example.com", :a, :in, 3600, {192, 168, 1, 1})
      a_record2 = Record.new("mail.example.com", :a, :in, 3600, {192, 168, 1, 2})

      options = Keyword.put(zone.options, :a_records, [a_record1, a_record2])
      zone = %{zone | options: options}

      stats = Validator.generate_statistics(zone)

      # Both A records should be grouped under same type key
      a_count =
        Enum.find_value(stats.record_counts, fn {type, count} ->
          if type == "A", do: count
        end)

      assert a_count == 2
    end

    test "generate_statistics with empty zone" do
      zone = Zone.new("example.com", :authoritative)
      stats = Validator.generate_statistics(zone)
      assert stats.total_records == 0
      assert stats.unique_names == 0
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

    test "security score higher with transfer restrictions" do
      zone1 = Zone.new("example1.com", :authoritative)
      zone2 = Zone.new("example2.com", :authoritative)

      options2 = Keyword.put(zone2.options, :allow_transfer, ["192.168.1.1"])
      zone2 = %{zone2 | options: options2}

      score1 = Validator.generate_security_assessment(zone1).overall_score
      score2 = Validator.generate_security_assessment(zone2).overall_score

      assert score2 > score1
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

    test "cache efficiency scales with average TTL" do
      zone1 = Zone.new("low-ttl.com", :authoritative)
      a_record1 = Record.new("www.low-ttl.com", :a, :in, 60, {1, 2, 3, 4})
      options1 = Keyword.put(zone1.options, :a_records, [a_record1])
      zone1 = %{zone1 | options: options1}

      zone2 = Zone.new("high-ttl.com", :authoritative)
      a_record2 = Record.new("www.high-ttl.com", :a, :in, 3600, {1, 2, 3, 4})
      options2 = Keyword.put(zone2.options, :a_records, [a_record2])
      zone2 = %{zone2 | options: options2}

      metrics1 = Validator.generate_performance_metrics(zone1)
      metrics2 = Validator.generate_performance_metrics(zone2)

      assert metrics2.cache_efficiency > metrics1.cache_efficiency
    end

    test "performance metrics zero records" do
      zone = Zone.new("empty.com", :authoritative)
      metrics = Validator.generate_performance_metrics(zone)
      assert metrics.record_count == 0
      assert metrics.cache_efficiency == 0.0
      assert metrics.zone_size == 0
    end
  end

  describe "Recommendations" do
    test "recommends NS records when missing" do
      zone = Zone.new("example.com", :authoritative)
      recommendations = Validator.generate_recommendations(zone)
      assert Enum.any?(recommendations, &String.contains?(&1, "NS records"))
    end

    test "recommends A records when missing" do
      zone = Zone.new("example.com", :authoritative)
      recommendations = Validator.generate_recommendations(zone)
      assert Enum.any?(recommendations, &String.contains?(&1, "A records"))
    end

    test "recommends DNSSEC when not enabled" do
      zone = Zone.new("example.com", :authoritative)
      recommendations = Validator.generate_recommendations(zone)
      assert Enum.any?(recommendations, &String.contains?(&1, "DNSSEC"))
    end

    test "fewer recommendations for well-configured zone" do
      zone = Zone.new("example.com", :authoritative)

      ns_record = Record.new("example.com", :ns, :in, 3600, "ns1.example.com")
      a_record = Record.new("ns1.example.com", :a, :in, 3600, {192, 168, 1, 1})
      dnskey_record = Record.new("example.com", :dnskey, :in, 3600, {256, 3, 8, "key"})

      options = Keyword.put(zone.options, :ns_records, [ns_record])
      options = Keyword.put(options, :a_records, [a_record])
      options = Keyword.put(options, :dnskey_records, [dnskey_record])
      options = Keyword.put(options, :dnssec_records, [])
      zone = %{zone | options: options}

      recommendations = Validator.generate_recommendations(zone)
      # Should have fewer recommendations
      assert length(recommendations) < 4
    end
  end
end
