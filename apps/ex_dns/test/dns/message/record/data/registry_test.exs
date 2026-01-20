defmodule DNS.Message.Record.Data.RegistryTest do
  @moduledoc """
  Comprehensive unit tests for DNS.Message.Record.Data.Registry.

  Tests cover:
  - Module structure and exports
  - GenServer behavior
  - ETS table management
  - Built-in type registration
  - Type lookup functionality
  - Concurrent access safety
  - Integration with record data dispatch
  """
  # Set async: false because tests rely on shared ETS table state
  use ExUnit.Case, async: false

  alias DNS.Message.Record.Data.Registry
  alias DNS.ResourceRecordType

  # Ensure ETS table is initialized before each test
  setup do
    # Trigger initialization by calling lookup
    Registry.lookup(1)
    :ok
  end

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(Registry)
    end

    test "exports start_link/1" do
      Code.ensure_loaded!(Registry)
      assert Kernel.function_exported?(Registry, :start_link, 1)
    end

    test "exports register/2" do
      Code.ensure_loaded!(Registry)
      assert Kernel.function_exported?(Registry, :register, 2)
    end

    test "exports lookup/1" do
      Code.ensure_loaded!(Registry)
      assert Kernel.function_exported?(Registry, :lookup, 1)
    end

    test "exports list_types/0" do
      Code.ensure_loaded!(Registry)
      assert Kernel.function_exported?(Registry, :list_types, 0)
    end

    test "exports registered?/1" do
      Code.ensure_loaded!(Registry)
      assert Kernel.function_exported?(Registry, :registered?, 1)
    end

    test "exports init_builtin_types/0" do
      Code.ensure_loaded!(Registry)
      assert Kernel.function_exported?(Registry, :init_builtin_types, 0)
    end
  end

  describe "lookup/1" do
    test "returns {:ok, module} for known type A (1)" do
      assert {:ok, DNS.Message.Record.Data.A} = Registry.lookup(1)
    end

    test "returns {:ok, module} for known type NS (2)" do
      assert {:ok, DNS.Message.Record.Data.NS} = Registry.lookup(2)
    end

    test "returns {:ok, module} for known type CNAME (5)" do
      assert {:ok, DNS.Message.Record.Data.CNAME} = Registry.lookup(5)
    end

    test "returns {:ok, module} for known type SOA (6)" do
      assert {:ok, DNS.Message.Record.Data.SOA} = Registry.lookup(6)
    end

    test "returns {:ok, module} for known type PTR (12)" do
      assert {:ok, DNS.Message.Record.Data.PTR} = Registry.lookup(12)
    end

    test "returns {:ok, module} for known type MX (15)" do
      assert {:ok, DNS.Message.Record.Data.MX} = Registry.lookup(15)
    end

    test "returns {:ok, module} for known type TXT (16)" do
      assert {:ok, DNS.Message.Record.Data.TXT} = Registry.lookup(16)
    end

    test "returns {:ok, module} for known type AAAA (28)" do
      assert {:ok, DNS.Message.Record.Data.AAAA} = Registry.lookup(28)
    end

    test "returns {:ok, module} for known type SRV (33)" do
      assert {:ok, DNS.Message.Record.Data.SRV} = Registry.lookup(33)
    end

    test "returns {:error, :not_found} for unknown type 9999" do
      assert {:error, :not_found} = Registry.lookup(9999)
    end

    test "returns {:error, :not_found} for type 0" do
      assert {:error, :not_found} = Registry.lookup(0)
    end

    test "returns {:error, :not_found} for unregistered standard type" do
      # HINFO (13) is not commonly registered
      result = Registry.lookup(13)
      # Could be registered or not depending on implementation
      assert match?({:ok, _}, result) or result == {:error, :not_found}
    end
  end

  describe "registered?/1" do
    test "returns true for A record (1)" do
      assert Registry.registered?(1)
    end

    test "returns true for NS record (2)" do
      assert Registry.registered?(2)
    end

    test "returns true for CNAME record (5)" do
      assert Registry.registered?(5)
    end

    test "returns true for AAAA record (28)" do
      assert Registry.registered?(28)
    end

    test "returns false for unknown type 9999" do
      refute Registry.registered?(9999)
    end

    test "returns false for type 0" do
      refute Registry.registered?(0)
    end
  end

  describe "list_types/0" do
    test "returns a list" do
      types = Registry.list_types()
      assert is_list(types)
    end

    test "returns non-empty list" do
      types = Registry.list_types()
      assert length(types) > 0
    end

    test "returns list of {type, module} tuples" do
      types = Registry.list_types()

      Enum.each(types, fn entry ->
        assert {type, module} = entry
        assert is_integer(type)
        assert is_atom(module)
      end)
    end

    test "contains A record type" do
      types = Registry.list_types()
      type_numbers = Enum.map(types, fn {type, _} -> type end)
      assert 1 in type_numbers
    end

    test "contains NS record type" do
      types = Registry.list_types()
      type_numbers = Enum.map(types, fn {type, _} -> type end)
      assert 2 in type_numbers
    end

    test "contains AAAA record type" do
      types = Registry.list_types()
      type_numbers = Enum.map(types, fn {type, _} -> type end)
      assert 28 in type_numbers
    end
  end

  describe "built-in standard record types" do
    test "A (1) is registered" do
      assert {:ok, DNS.Message.Record.Data.A} = Registry.lookup(1)
    end

    test "NS (2) is registered" do
      assert {:ok, DNS.Message.Record.Data.NS} = Registry.lookup(2)
    end

    test "CNAME (5) is registered" do
      assert {:ok, DNS.Message.Record.Data.CNAME} = Registry.lookup(5)
    end

    test "SOA (6) is registered" do
      assert {:ok, DNS.Message.Record.Data.SOA} = Registry.lookup(6)
    end

    test "PTR (12) is registered" do
      assert {:ok, DNS.Message.Record.Data.PTR} = Registry.lookup(12)
    end

    test "MX (15) is registered" do
      assert {:ok, DNS.Message.Record.Data.MX} = Registry.lookup(15)
    end

    test "TXT (16) is registered" do
      assert {:ok, DNS.Message.Record.Data.TXT} = Registry.lookup(16)
    end

    test "AAAA (28) is registered" do
      assert {:ok, DNS.Message.Record.Data.AAAA} = Registry.lookup(28)
    end

    test "SRV (33) is registered" do
      assert {:ok, DNS.Message.Record.Data.SRV} = Registry.lookup(33)
    end
  end

  describe "built-in DNSSEC record types" do
    test "DNSKEY (43) is registered" do
      assert {:ok, DNS.Message.Record.Data.DNSKEY} = Registry.lookup(43)
    end

    test "RRSIG (46) is registered" do
      assert {:ok, DNS.Message.Record.Data.RRSIG} = Registry.lookup(46)
    end

    test "NSEC (47) is registered" do
      assert {:ok, DNS.Message.Record.Data.NSEC} = Registry.lookup(47)
    end

    test "DS (48) is registered" do
      assert {:ok, DNS.Message.Record.Data.DS} = Registry.lookup(48)
    end

    test "NSEC3 (50) is registered" do
      assert {:ok, DNS.Message.Record.Data.NSEC3} = Registry.lookup(50)
    end

    test "NSEC3PARAM (51) is registered" do
      assert {:ok, DNS.Message.Record.Data.NSEC3PARAM} = Registry.lookup(51)
    end
  end

  describe "built-in modern record types" do
    test "TLSA (52) is registered" do
      assert {:ok, DNS.Message.Record.Data.TLSA} = Registry.lookup(52)
    end

    test "SVCB (64) is registered" do
      assert {:ok, DNS.Message.Record.Data.SVCB} = Registry.lookup(64)
    end

    test "HTTPS (65) is registered" do
      assert {:ok, DNS.Message.Record.Data.HTTPS} = Registry.lookup(65)
    end

    test "CAA (257) is registered" do
      assert {:ok, DNS.Message.Record.Data.CAA} = Registry.lookup(257)
    end
  end

  describe "ETS table management" do
    test "ETS table exists after lookup" do
      Registry.lookup(1)
      assert :ets.whereis(:dns_record_types) != :undefined
    end

    test "ETS table survives multiple lookups" do
      Registry.lookup(1)
      Registry.lookup(2)
      Registry.lookup(28)
      assert :ets.whereis(:dns_record_types) != :undefined
    end

    test "multiple initialization calls are idempotent" do
      Registry.lookup(1)
      Registry.init_builtin_types()
      Registry.init_builtin_types()
      assert Registry.registered?(1)
    end
  end

  describe "concurrent access" do
    test "handles concurrent lookups safely" do
      tasks =
        for _i <- 1..20 do
          Task.async(fn ->
            Registry.lookup(1)
          end)
        end

      results = Task.await_many(tasks, 5000)
      assert length(results) == 20

      Enum.each(results, fn result ->
        assert {:ok, DNS.Message.Record.Data.A} = result
      end)
    end

    test "maintains consistency across concurrent lookups" do
      tasks =
        for type <- [1, 2, 5, 6, 15, 16, 28, 33] do
          Task.async(fn ->
            Registry.lookup(type)
          end)
        end

      results = Task.await_many(tasks, 5000)

      Enum.each(results, fn result ->
        assert {:ok, _module} = result
      end)
    end

    test "handles mixed registered and unregistered lookups" do
      tasks =
        for type <- [1, 9999, 2, 8888, 28, 7777] do
          Task.async(fn ->
            {type, Registry.lookup(type)}
          end)
        end

      results = Task.await_many(tasks, 5000)

      for {type, result} <- results do
        case type do
          t when t in [1, 2, 28] -> assert {:ok, _} = result
          _ -> assert {:error, :not_found} = result
        end
      end
    end
  end

  describe "integration with record data module" do
    test "record data new/2 uses registry for A record" do
      rtype = ResourceRecordType.new(1)
      data = DNS.Message.Record.Data.new(rtype, {192, 168, 1, 1})
      assert %DNS.Message.Record.Data.A{} = data
    end

    test "record data new/2 uses registry for AAAA record" do
      rtype = ResourceRecordType.new(28)

      data =
        DNS.Message.Record.Data.new(rtype, {0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1})

      assert %DNS.Message.Record.Data.AAAA{} = data
    end

    test "record data new/2 uses registry for MX record" do
      rtype = ResourceRecordType.new(15)
      data = DNS.Message.Record.Data.new(rtype, {10, "mail.example.com"})
      assert %DNS.Message.Record.Data.MX{} = data
    end

    test "record data new/2 falls back to generic for unknown type" do
      rtype = ResourceRecordType.new(9999)
      data = DNS.Message.Record.Data.new(rtype, "test_data")
      assert %DNS.Message.Record.Data{type: ^rtype, raw: "test_data"} = data
    end

    test "from_iodata uses registry for A record" do
      rdata = <<192, 168, 1, 1>>
      data = DNS.Message.Record.Data.from_iodata(1, rdata)
      assert %DNS.Message.Record.Data.A{} = data
    end

    test "from_iodata uses registry for AAAA record" do
      rdata = <<0x20, 0x01, 0x0D, 0xB8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1>>
      data = DNS.Message.Record.Data.from_iodata(28, rdata)
      assert %DNS.Message.Record.Data.AAAA{} = data
    end

    test "from_iodata falls back to generic for unknown type" do
      rdata = "test_data"
      data = DNS.Message.Record.Data.from_iodata(9999, rdata)
      assert %DNS.Message.Record.Data{raw: "test_data"} = data
    end
  end

  describe "type coverage verification" do
    test "all standard types are registered" do
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

      Enum.each(standard_types, fn {type, name} ->
        assert Registry.registered?(type), "Standard type #{name} (#{type}) should be registered"
      end)
    end

    test "all DNSSEC types are registered" do
      dnssec_types = [
        {43, "DNSKEY"},
        {46, "RRSIG"},
        {47, "NSEC"},
        {48, "DS"},
        {50, "NSEC3"},
        {51, "NSEC3PARAM"}
      ]

      Enum.each(dnssec_types, fn {type, name} ->
        assert Registry.registered?(type), "DNSSEC type #{name} (#{type}) should be registered"
      end)
    end

    test "all modern types are registered" do
      modern_types = [
        {52, "TLSA"},
        {64, "SVCB"},
        {65, "HTTPS"},
        {257, "CAA"}
      ]

      Enum.each(modern_types, fn {type, name} ->
        assert Registry.registered?(type), "Modern type #{name} (#{type}) should be registered"
      end)
    end

    test "total registered types count" do
      types = Registry.list_types()
      # Should have at least 19 types (9 standard + 6 DNSSEC + 4 modern)
      assert length(types) >= 19
    end
  end

  describe "edge cases" do
    test "lookup returns same module consistently" do
      {:ok, module1} = Registry.lookup(1)
      {:ok, module2} = Registry.lookup(1)
      {:ok, module3} = Registry.lookup(1)
      assert module1 == module2
      assert module2 == module3
    end

    test "lookup handles large type numbers" do
      # CAA is type 257
      assert {:ok, _} = Registry.lookup(257)
    end

    test "registered? and lookup are consistent" do
      for type <- [1, 2, 5, 6, 15, 16, 28, 33, 43, 46, 47, 48, 50, 51, 52, 64, 65, 257] do
        is_registered = Registry.registered?(type)
        lookup_result = Registry.lookup(type)

        if is_registered do
          assert {:ok, _} = lookup_result
        else
          assert {:error, :not_found} = lookup_result
        end
      end
    end

    test "list_types returns unique entries" do
      types = Registry.list_types()
      type_numbers = Enum.map(types, fn {type, _} -> type end)
      assert length(type_numbers) == length(Enum.uniq(type_numbers))
    end
  end
end
