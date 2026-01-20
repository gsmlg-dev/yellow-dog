defmodule YellowDog.Mdns.RecordBuilderTest do
  use ExUnit.Case, async: true

  alias YellowDog.Mdns.RecordBuilder
  alias DNS.Message.{Record, Question}

  # Test service fixture
  @test_service %{
    id: "test-service-001",
    name: "Test Web Server",
    type: "_http._tcp",
    domain: "local",
    fqdn: "Test Web Server._http._tcp.local",
    host: "myhost.local",
    port: 8080,
    priority: 0,
    weight: 0,
    ttl: 4500,
    txt_records: %{"path" => "/api", "version" => "1.0"},
    addresses: [{192, 168, 1, 100}, {0xFE80, 0, 0, 0, 0, 0, 0, 1}]
  }

  @service_no_txt %{
    @test_service
    | txt_records: %{}
  }

  @service_ipv4_only %{
    @test_service
    | addresses: [{192, 168, 1, 100}]
  }

  @service_ipv6_only %{
    @test_service
    | addresses: [{0xFE80, 0, 0, 0, 0, 0, 0, 1}]
  }

  describe "build_all_records/1" do
    test "returns all record types" do
      records = RecordBuilder.build_all_records(@test_service)

      assert Map.has_key?(records, :ptr)
      assert Map.has_key?(records, :srv)
      assert Map.has_key?(records, :txt)
      assert Map.has_key?(records, :a)
      assert Map.has_key?(records, :aaaa)
    end

    test "returns proper Record structs" do
      records = RecordBuilder.build_all_records(@test_service)

      assert %Record{} = records.ptr
      assert %Record{} = records.srv
      assert %Record{} = records.txt
      assert [%Record{} | _] = records.a
      assert [%Record{} | _] = records.aaaa
    end
  end

  describe "build_ptr_record/1" do
    test "creates PTR record with correct name" do
      record = RecordBuilder.build_ptr_record(@test_service)

      assert record.name == "_http._tcp.local"
      assert record.type == :PTR
      assert record.class == :IN
    end

    test "PTR data points to service FQDN" do
      record = RecordBuilder.build_ptr_record(@test_service)

      assert record.data == "Test Web Server._http._tcp.local"
    end

    test "uses service TTL" do
      record = RecordBuilder.build_ptr_record(@test_service)

      assert record.ttl == 4500
    end

    test "uses default TTL when not specified" do
      service = Map.put(@test_service, :ttl, nil)
      record = RecordBuilder.build_ptr_record(service)

      assert record.ttl == 4500
    end
  end

  describe "build_srv_record/1" do
    test "creates SRV record with correct name" do
      record = RecordBuilder.build_srv_record(@test_service)

      assert record.name == "Test Web Server._http._tcp.local"
      assert record.type == :SRV
      assert record.class == :IN
    end

    test "SRV data contains correct fields" do
      record = RecordBuilder.build_srv_record(@test_service)

      assert record.data.priority == 0
      assert record.data.weight == 0
      assert record.data.port == 8080
      assert record.data.target == "myhost.local"
    end

    test "uses service priority and weight" do
      service = %{@test_service | priority: 10, weight: 5}
      record = RecordBuilder.build_srv_record(service)

      assert record.data.priority == 10
      assert record.data.weight == 5
    end
  end

  describe "build_txt_record/1" do
    test "creates TXT record with correct name" do
      record = RecordBuilder.build_txt_record(@test_service)

      assert record.name == "Test Web Server._http._tcp.local"
      assert record.type == :TXT
      assert record.class == :IN
    end

    test "TXT data contains key=value pairs" do
      record = RecordBuilder.build_txt_record(@test_service)

      assert is_list(record.data)
      # Check that both key=value pairs exist
      assert "path=/api" in record.data or "version=1.0" in record.data
    end

    test "empty TXT records contain single empty string" do
      record = RecordBuilder.build_txt_record(@service_no_txt)

      assert record.data == [""]
    end
  end

  describe "build_a_records/1" do
    test "creates A records for IPv4 addresses" do
      records = RecordBuilder.build_a_records(@test_service)

      assert length(records) == 1
      assert hd(records).type == :A
      assert hd(records).data == {192, 168, 1, 100}
    end

    test "A records use host name" do
      records = RecordBuilder.build_a_records(@test_service)

      assert hd(records).name == "myhost.local"
    end

    test "A records use short host TTL" do
      records = RecordBuilder.build_a_records(@test_service)

      assert hd(records).ttl == 120
    end

    test "returns empty list for IPv6-only service" do
      records = RecordBuilder.build_a_records(@service_ipv6_only)

      assert records == []
    end

    test "handles multiple IPv4 addresses" do
      service = %{@test_service | addresses: [{192, 168, 1, 100}, {10, 0, 0, 1}]}
      records = RecordBuilder.build_a_records(service)

      assert length(records) == 2
    end
  end

  describe "build_aaaa_records/1" do
    test "creates AAAA records for IPv6 addresses" do
      records = RecordBuilder.build_aaaa_records(@test_service)

      assert length(records) == 1
      assert hd(records).type == :AAAA
      assert hd(records).data == {0xFE80, 0, 0, 0, 0, 0, 0, 1}
    end

    test "AAAA records use host name" do
      records = RecordBuilder.build_aaaa_records(@test_service)

      assert hd(records).name == "myhost.local"
    end

    test "AAAA records use short host TTL" do
      records = RecordBuilder.build_aaaa_records(@test_service)

      assert hd(records).ttl == 120
    end

    test "returns empty list for IPv4-only service" do
      records = RecordBuilder.build_aaaa_records(@service_ipv4_only)

      assert records == []
    end
  end

  describe "build_records_for_question/2" do
    test "PTR query returns PTR in answers with additional records" do
      question = %Question{name: "_http._tcp.local", type: :PTR, class: :IN}
      result = RecordBuilder.build_records_for_question(@test_service, question)

      assert length(result.answers) == 1
      assert hd(result.answers).type == :PTR
      # SRV, TXT, and address records in additional
      assert length(result.additional) >= 2
    end

    test "SRV query returns SRV in answers" do
      question = %Question{name: "Test Web Server._http._tcp.local", type: :SRV, class: :IN}
      result = RecordBuilder.build_records_for_question(@test_service, question)

      assert length(result.answers) == 1
      assert hd(result.answers).type == :SRV
    end

    test "TXT query returns TXT in answers" do
      question = %Question{name: "Test Web Server._http._tcp.local", type: :TXT, class: :IN}
      result = RecordBuilder.build_records_for_question(@test_service, question)

      assert length(result.answers) == 1
      assert hd(result.answers).type == :TXT
    end

    test "A query returns A records in answers" do
      question = %Question{name: "myhost.local", type: :A, class: :IN}
      result = RecordBuilder.build_records_for_question(@test_service, question)

      assert length(result.answers) >= 1
      assert Enum.all?(result.answers, fn r -> r.type == :A end)
    end

    test "AAAA query returns AAAA records in answers" do
      question = %Question{name: "myhost.local", type: :AAAA, class: :IN}
      result = RecordBuilder.build_records_for_question(@test_service, question)

      assert length(result.answers) >= 1
      assert Enum.all?(result.answers, fn r -> r.type == :AAAA end)
    end

    test "ANY query on host returns address records" do
      question = %Question{name: "myhost.local", type: :ANY, class: :IN}
      result = RecordBuilder.build_records_for_question(@test_service, question)

      assert length(result.answers) >= 1
    end

    test "unmatched query returns empty result" do
      question = %Question{name: "other.local", type: :A, class: :IN}
      result = RecordBuilder.build_records_for_question(@test_service, question)

      assert result.answers == []
      assert result.authority == []
      assert result.additional == []
    end

    test "handles case-insensitive name matching" do
      question = %Question{name: "MYHOST.LOCAL", type: :A, class: :IN}
      result = RecordBuilder.build_records_for_question(@test_service, question)

      assert length(result.answers) >= 1
    end

    test "handles trailing dot in name" do
      question = %Question{name: "myhost.local.", type: :A, class: :IN}
      result = RecordBuilder.build_records_for_question(@test_service, question)

      assert length(result.answers) >= 1
    end
  end

  describe "build_goodbye_records/1" do
    test "returns all record types with TTL=0" do
      records = RecordBuilder.build_goodbye_records(@test_service)

      assert is_list(records)
      assert length(records) >= 3

      # All records should have TTL=0
      Enum.each(records, fn record ->
        assert record.ttl == 0, "Expected TTL=0 for goodbye record, got #{record.ttl}"
      end)
    end

    test "includes PTR, SRV, TXT records" do
      records = RecordBuilder.build_goodbye_records(@test_service)
      types = Enum.map(records, & &1.type)

      assert :PTR in types
      assert :SRV in types
      assert :TXT in types
    end

    test "includes address records" do
      records = RecordBuilder.build_goodbye_records(@test_service)
      types = Enum.map(records, & &1.type)

      assert :A in types
      assert :AAAA in types
    end
  end

  describe "validate_service_for_records/1" do
    test "returns :ok for valid service" do
      assert :ok = RecordBuilder.validate_service_for_records(@test_service)
    end

    test "returns error for missing FQDN" do
      service = %{@test_service | fqdn: nil}

      assert {:error, "Service FQDN is required"} =
               RecordBuilder.validate_service_for_records(service)
    end

    test "returns error for empty FQDN" do
      service = %{@test_service | fqdn: ""}

      assert {:error, "Service FQDN is required"} =
               RecordBuilder.validate_service_for_records(service)
    end

    test "returns error for missing host" do
      service = %{@test_service | host: nil}

      assert {:error, "Service host is required"} =
               RecordBuilder.validate_service_for_records(service)
    end

    test "returns error for invalid port" do
      service = %{@test_service | port: 0}

      assert {:error, "Valid port number is required"} =
               RecordBuilder.validate_service_for_records(service)
    end

    test "returns error for port out of range" do
      service = %{@test_service | port: 70000}

      assert {:error, "Valid port number is required"} =
               RecordBuilder.validate_service_for_records(service)
    end
  end

  describe "calculate_record_size/1" do
    test "returns positive integer" do
      size = RecordBuilder.calculate_record_size(@test_service)

      assert is_integer(size)
      assert size > 0
    end

    test "larger service has larger size" do
      small_service = %{@test_service | txt_records: %{}}
      large_service = %{@test_service | txt_records: %{"a" => "b", "c" => "d", "e" => "f"}}

      small_size = RecordBuilder.calculate_record_size(small_service)
      large_size = RecordBuilder.calculate_record_size(large_service)

      assert large_size >= small_size
    end

    test "more addresses increases size" do
      single_addr = %{@test_service | addresses: [{192, 168, 1, 1}]}

      multi_addr = %{
        @test_service
        | addresses: [{192, 168, 1, 1}, {192, 168, 1, 2}, {192, 168, 1, 3}]
      }

      single_size = RecordBuilder.calculate_record_size(single_addr)
      multi_size = RecordBuilder.calculate_record_size(multi_addr)

      assert multi_size > single_size
    end
  end
end
