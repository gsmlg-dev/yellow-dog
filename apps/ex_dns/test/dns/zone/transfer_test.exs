defmodule DNS.Zone.TransferTest do
  use ExUnit.Case

  alias DNS.Zone
  alias DNS.Zone.Transfer
  alias DNS.Zone.Manager
  alias DNS.Message.Record

  setup do
    Manager.init()
    :ok
  end

  describe "AXFR zone transfer" do
    test "perform_axfr returns zone records" do
      zone_name = "example.com"

      # Create test zone
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
      a_record = Record.new("www.example.com", :a, :in, 3600, {192, 168, 1, 1})

      options = Keyword.put(zone.options, :soa_records, [soa_record])
      options = Keyword.put(options, :ns_records, [ns_record])
      options = Keyword.put(options, :a_records, [a_record])

      zone = %{zone | options: options}
      Manager.create_zone(zone_name, :authoritative, zone.options)

      # Test AXFR
      assert {:ok, records} = Transfer.axfr(zone_name)
      assert is_list(records)
      assert length(records) >= 3
    end

    test "axfr returns error for non-existent zone" do
      assert {:error, "Zone not found: nonexistent.com"} = Transfer.axfr("nonexistent.com")
    end
  end

  describe "IXFR zone transfer" do
    test "ixfr returns empty list when no changes" do
      zone_name = "example.com"

      # Create test zone
      zone = Zone.new(zone_name, :authoritative)

      soa_record =
        Record.new(
          zone_name,
          :soa,
          :in,
          3600,
          {"ns1.example.com", "admin.example.com", 1, 3600, 1800, 604_800, 300}
        )

      options = Keyword.put(zone.options, :soa_records, [soa_record])
      zone = %{zone | options: options}
      Manager.create_zone(zone_name, :authoritative, zone.options)

      # Test IXFR with same serial
      assert {:ok, []} = Transfer.ixfr(zone_name, 1)
    end

    test "ixfr returns records when serial is lower" do
      zone_name = "example.com"

      # Create test zone
      zone = Zone.new(zone_name, :authoritative)

      soa_record =
        Record.new(
          zone_name,
          :soa,
          :in,
          3600,
          {"ns1.example.com", "admin.example.com", 10, 3600, 1800, 604_800, 300}
        )

      options = Keyword.put(zone.options, :soa_records, [soa_record])
      zone = %{zone | options: options}
      Manager.create_zone(zone_name, :authoritative, zone.options)

      # Test IXFR with lower serial - should return full zone
      assert {:ok, records} = Transfer.ixfr(zone_name, 5)
      assert is_list(records)
    end
  end

  describe "Zone transfer authorization" do
    test "transfer_allowed? with :any" do
      zone_name = "example.com"
      zone = Zone.new(zone_name, :authoritative)
      options = Keyword.put(zone.options, :allow_transfer, :any)
      zone = %{zone | options: options}

      Manager.create_zone(zone_name, :authoritative, zone.options)

      assert Transfer.transfer_allowed?(zone_name, {192, 168, 1, 1})
    end

    test "transfer_allowed? with :none" do
      zone_name = "example.com"
      zone = Zone.new(zone_name, :authoritative)
      options = Keyword.put(zone.options, :allow_transfer, :none)
      zone = %{zone | options: options}

      Manager.create_zone(zone_name, :authoritative, zone.options)

      refute Transfer.transfer_allowed?(zone_name, {192, 168, 1, 1})
    end

    test "transfer_allowed? with specific IPs" do
      zone_name = "example.com"
      zone = Zone.new(zone_name, :authoritative)
      options = Keyword.put(zone.options, :allow_transfer, [{192, 168, 1, 100}])
      zone = %{zone | options: options}

      Manager.create_zone(zone_name, :authoritative, zone.options)

      assert Transfer.transfer_allowed?(zone_name, {192, 168, 1, 100})
      refute Transfer.transfer_allowed?(zone_name, {192, 168, 1, 1})
    end
  end

  describe "Transfer response creation" do
    test "create_transfer_response with valid records" do
      zone_name = "example.com"

      records = [
        Record.new(
          zone_name,
          :soa,
          :in,
          3600,
          {"ns1.example.com", "admin.example.com", 1, 3600, 1800, 604_800, 300}
        ),
        Record.new(zone_name, :ns, :in, 3600, "ns1.example.com")
      ]

      assert {:ok, response} = Transfer.create_transfer_response(zone_name, records, :axfr)
      assert response.zone_name == zone_name
      assert response.transfer_type == :axfr
      assert response.count == 2
      assert is_integer(response.serial)
    end

    test "create_transfer_response with empty records" do
      assert {:error, "No records to transfer"} =
               Transfer.create_transfer_response("example.com", [], :axfr)
    end
  end

  describe "Apply zone transfer" do
    test "apply_axfr creates zone with transferred records" do
      zone_name = "transferred.com"

      records = [
        Record.new(
          zone_name,
          :soa,
          :in,
          3600,
          {"ns1.transferred.com", "admin.transferred.com", 1, 3600, 1800, 604_800, 300}
        ),
        Record.new(zone_name, :ns, :in, 3600, "ns1.transferred.com"),
        Record.new("www.transferred.com", :a, :in, 3600, {192, 168, 1, 1})
      ]

      assert {:ok, zone} = Transfer.apply_transfer(zone_name, records, transfer_type: :axfr)
      assert zone.name.value == zone_name

      # Verify zone was created
      assert {:ok, stored_zone} = Manager.get_zone(zone_name)
      assert stored_zone.name.value == zone_name
    end

    test "apply_axfr updates existing zone" do
      zone_name = "update-example.com"

      # Create initial zone
      initial_zone = Zone.new(zone_name, :authoritative)

      initial_soa =
        Record.new(
          zone_name,
          :soa,
          :in,
          3600,
          {"ns1.example.com", "admin.example.com", 1, 3600, 1800, 604_800, 300}
        )

      options = Keyword.put(initial_zone.options, :soa_records, [initial_soa])
      initial_zone = %{initial_zone | options: options}

      Manager.create_zone(zone_name, :authoritative, initial_zone.options)

      # Apply transfer with updated records
      updated_records = [
        Record.new(
          zone_name,
          :soa,
          :in,
          3600,
          {"ns1.example.com", "admin.example.com", 2, 3600, 1800, 604_800, 300}
        ),
        Record.new(zone_name, :ns, :in, 3600, "ns1.example.com"),
        Record.new("www.example.com", :a, :in, 3600, {192, 168, 1, 1})
      ]

      assert {:ok, zone} =
               Transfer.apply_transfer(zone_name, updated_records, transfer_type: :axfr)

      assert zone.name.value == zone_name
    end
  end

  describe "Transfer request creation" do
    test "create_transfer_request with AXFR" do
      zone_name = "example.com"

      assert {:ok, request} = Transfer.create_transfer_request(zone_name, :axfr)
      assert request.zone_name == zone_name
      assert request.transfer_type == :axfr
      assert is_nil(request.serial)
      assert %DateTime{} = request.timestamp
    end

    test "create_transfer_request with IXFR and serial" do
      zone_name = "example.com"

      assert {:ok, request} = Transfer.create_transfer_request(zone_name, :ixfr, serial: 12345)
      assert request.zone_name == zone_name
      assert request.transfer_type == :ixfr
      assert request.serial == 12345
    end

    test "create_transfer_request with client IP" do
      zone_name = "example.com"
      client_ip = {192, 168, 1, 1}

      assert {:ok, request} =
               Transfer.create_transfer_request(zone_name, :axfr, client_ip: client_ip)

      assert request.client_ip == client_ip
    end
  end
end
