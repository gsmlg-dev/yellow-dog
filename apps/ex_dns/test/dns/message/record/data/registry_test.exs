defmodule DNS.Message.Record.Data.RegistryTest do
  use ExUnit.Case

  alias DNS.Message.Record.Data.Registry
  alias DNS.ResourceRecordType

  describe "registry functionality" do
    test "initializes with built-in record types" do
      # Ensure the registry is initialized
      # A record
      Registry.lookup(1)

      # Check that built-in types are registered
      # A
      assert Registry.registered?(1)
      # NS
      assert Registry.registered?(2)
      # CNAME
      assert Registry.registered?(5)
      # SOA
      assert Registry.registered?(6)
      # TXT
      assert Registry.registered?(16)
      # AAAA
      assert Registry.registered?(28)
    end

    test "lookup returns correct module for known types" do
      assert {:ok, DNS.Message.Record.Data.A} = Registry.lookup(1)
      assert {:ok, DNS.Message.Record.Data.NS} = Registry.lookup(2)
      assert {:ok, DNS.Message.Record.Data.CNAME} = Registry.lookup(5)
      assert {:ok, DNS.Message.Record.Data.AAAA} = Registry.lookup(28)
    end

    test "lookup returns error for unknown types" do
      assert {:error, :not_found} = Registry.lookup(9999)
      assert {:error, :not_found} = Registry.lookup(0)
    end

    test "can list all registered types" do
      # Ensure registry is initialized
      Registry.lookup(1)

      types = Registry.list_types()
      assert is_list(types)
      assert length(types) > 0

      # Check that some expected types are present
      type_numbers = Enum.map(types, fn {type, _module} -> type end)
      # A
      assert 1 in type_numbers
      # NS
      assert 2 in type_numbers
      # AAAA
      assert 28 in type_numbers
    end

    test "registered? function works correctly" do
      # Ensure registry is initialized first
      Registry.lookup(1)

      # A
      assert Registry.registered?(1)
      # AAAA
      assert Registry.registered?(28)
      refute Registry.registered?(9999)
      refute Registry.registered?(0)
    end
  end

  describe "registry initialization" do
    test "handles multiple initialization calls gracefully" do
      # First initialization
      Registry.lookup(1)

      # Second initialization should not cause issues
      Registry.lookup(1)

      assert Registry.registered?(1)
    end

    test "ensures ETS table exists after lookup" do
      # Force initialization
      Registry.lookup(1)

      # Check that the ETS table exists
      assert :ets.whereis(:dns_record_types) != :undefined
    end
  end

  describe "integration with record data module" do
    test "record data module uses registry for known types" do
      # A record
      rtype = ResourceRecordType.new(1)
      data = DNS.Message.Record.Data.new(rtype, {192, 168, 1, 1})

      # Should return an A record struct, not generic data
      assert %DNS.Message.Record.Data.A{} = data
    end

    test "record data module falls back to generic for unknown types" do
      # Unknown type
      rtype = ResourceRecordType.new(9999)
      data = DNS.Message.Record.Data.new(rtype, "test_data")

      # Should return generic data struct
      assert %DNS.Message.Record.Data{type: ^rtype, raw: "test_data"} = data
    end

    test "from_iodata uses registry for known types" do
      rdata = <<192, 168, 1, 1>>
      # A record
      data = DNS.Message.Record.Data.from_iodata(1, rdata)

      assert %DNS.Message.Record.Data.A{} = data
    end

    test "from_iodata falls back to generic for unknown types" do
      rdata = "test_data"
      # Unknown type
      data = DNS.Message.Record.Data.from_iodata(9999, rdata)

      assert %DNS.Message.Record.Data{raw: "test_data"} = data
    end
  end

  describe "registry behavior" do
    # No setup cleanup - let the ETS table persist for the duration of the test suite
    # This prevents race conditions between test cleanup and concurrent access

    test "maintains consistency across multiple lookups" do
      # Multiple lookups should return the same result
      assert {:ok, module1} = Registry.lookup(1)
      assert {:ok, module2} = Registry.lookup(1)
      assert module1 == module2
    end

    test "handles concurrent lookups safely" do
      # Spawn multiple processes doing lookups simultaneously
      tasks =
        for _i <- 1..10 do
          Task.async(fn ->
            Registry.lookup(1)
          end)
        end

      results = Task.await_many(tasks, 1000)
      assert length(results) == 10

      # All results should be the same
      first_result = hd(results)
      assert Enum.all?(results, &(&1 == first_result))
    end
  end

  describe "built-in type coverage" do
    test "includes all standard record types" do
      # Ensure registry is initialized
      Registry.lookup(1)

      standard_types = [
        {1, "A"},
        {2, "NS"},
        {5, "CNAME"},
        {6, "SOA"},
        {12, "PTR"},
        {15, "MX"},
        {16, "TXT"},
        {28, "AAAA"},
        {33, "SRV"}
      ]

      Enum.each(standard_types, fn {type, _name} ->
        assert Registry.registered?(type), "Standard type #{type} should be registered"
        assert {:ok, _module} = Registry.lookup(type)
      end)
    end

    test "includes DNSSEC record types" do
      # Ensure registry is initialized
      Registry.lookup(1)

      dnssec_types = [
        {43, "DNSKEY"},
        {46, "RRSIG"},
        {47, "NSEC"},
        {48, "DS"},
        {50, "NSEC3"},
        {51, "NSEC3PARAM"}
      ]

      Enum.each(dnssec_types, fn {type, _name} ->
        assert Registry.registered?(type), "DNSSEC type #{type} should be registered"
        assert {:ok, _module} = Registry.lookup(type)
      end)
    end

    test "includes modern record types" do
      # Ensure registry is initialized
      Registry.lookup(1)

      modern_types = [
        {52, "TLSA"},
        {64, "SVCB"},
        {65, "HTTPS"},
        {257, "CAA"}
      ]

      Enum.each(modern_types, fn {type, _name} ->
        assert Registry.registered?(type), "Modern type #{type} should be registered"
        assert {:ok, _module} = Registry.lookup(type)
      end)
    end
  end
end
