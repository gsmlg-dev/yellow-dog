defmodule DHCP.SecureRandomTest do
  @moduledoc """
  Comprehensive unit tests for DHCP.SecureRandom.

  Tests cover:
  - DHCPv4 transaction ID generation
  - DHCPv6 transaction ID generation
  - IA ID generation
  - Random bytes generation
  - Uniform random number generation
  - Cryptographic properties (uniqueness, range bounds)
  """
  use ExUnit.Case, async: true

  alias DHCP.SecureRandom

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(SecureRandom)
    end

    test "exports generate_dhcpv4_xid/0" do
      Code.ensure_loaded!(SecureRandom)
      assert Kernel.function_exported?(SecureRandom, :generate_dhcpv4_xid, 0)
    end

    test "exports generate_dhcpv6_transaction_id/0" do
      Code.ensure_loaded!(SecureRandom)
      assert Kernel.function_exported?(SecureRandom, :generate_dhcpv6_transaction_id, 0)
    end

    test "exports generate_ia_id/0" do
      Code.ensure_loaded!(SecureRandom)
      assert Kernel.function_exported?(SecureRandom, :generate_ia_id, 0)
    end

    test "exports generate_bytes/1" do
      Code.ensure_loaded!(SecureRandom)
      assert Kernel.function_exported?(SecureRandom, :generate_bytes, 1)
    end

    test "exports uniform/2" do
      Code.ensure_loaded!(SecureRandom)
      assert Kernel.function_exported?(SecureRandom, :uniform, 2)
    end
  end

  describe "generate_dhcpv4_xid/0" do
    test "returns a non-negative integer" do
      xid = SecureRandom.generate_dhcpv4_xid()

      assert is_integer(xid)
      assert xid >= 0
    end

    test "returns value within 32-bit range" do
      xid = SecureRandom.generate_dhcpv4_xid()

      assert xid <= 0xFFFFFFFF
    end

    test "generates unique values on repeated calls" do
      xids = for _ <- 1..100, do: SecureRandom.generate_dhcpv4_xid()

      # With 32-bit space and 100 values, all should be unique
      unique_xids = Enum.uniq(xids)
      assert length(unique_xids) == 100
    end

    test "generates full range of values" do
      # Generate many values and check we get variety
      xids = for _ <- 1..1000, do: SecureRandom.generate_dhcpv4_xid()

      # Check we have values in different ranges
      low_values = Enum.count(xids, &(&1 < 0x7FFFFFFF))
      high_values = Enum.count(xids, &(&1 >= 0x7FFFFFFF))

      # Should have values in both halves (statistically)
      assert low_values > 0
      assert high_values > 0
    end
  end

  describe "generate_dhcpv6_transaction_id/0" do
    test "returns a non-negative integer" do
      tid = SecureRandom.generate_dhcpv6_transaction_id()

      assert is_integer(tid)
      assert tid >= 0
    end

    test "returns value within 24-bit range" do
      tid = SecureRandom.generate_dhcpv6_transaction_id()

      assert tid <= 0xFFFFFF
    end

    test "generates unique values on repeated calls" do
      tids = for _ <- 1..100, do: SecureRandom.generate_dhcpv6_transaction_id()

      unique_tids = Enum.uniq(tids)
      assert length(unique_tids) == 100
    end

    test "generates values across the 24-bit range" do
      tids = for _ <- 1..1000, do: SecureRandom.generate_dhcpv6_transaction_id()

      # Check distribution across range
      low_values = Enum.count(tids, &(&1 < 0x800000))
      high_values = Enum.count(tids, &(&1 >= 0x800000))

      assert low_values > 0
      assert high_values > 0
    end
  end

  describe "generate_ia_id/0" do
    test "returns a non-negative integer" do
      iaid = SecureRandom.generate_ia_id()

      assert is_integer(iaid)
      assert iaid >= 0
    end

    test "returns value within 32-bit range" do
      iaid = SecureRandom.generate_ia_id()

      assert iaid <= 0xFFFFFFFF
    end

    test "generates unique values on repeated calls" do
      iaids = for _ <- 1..100, do: SecureRandom.generate_ia_id()

      unique_iaids = Enum.uniq(iaids)
      assert length(unique_iaids) == 100
    end
  end

  describe "generate_bytes/1" do
    test "returns binary of requested length" do
      bytes = SecureRandom.generate_bytes(16)

      assert is_binary(bytes)
      assert byte_size(bytes) == 16
    end

    test "generates 1 byte" do
      bytes = SecureRandom.generate_bytes(1)

      assert byte_size(bytes) == 1
    end

    test "generates large number of bytes" do
      bytes = SecureRandom.generate_bytes(1024)

      assert byte_size(bytes) == 1024
    end

    test "generates unique values on repeated calls" do
      bytes_list = for _ <- 1..100, do: SecureRandom.generate_bytes(16)

      unique_bytes = Enum.uniq(bytes_list)
      assert length(unique_bytes) == 100
    end

    test "generates different lengths correctly" do
      for len <- [1, 2, 4, 8, 16, 32, 64, 128, 256] do
        bytes = SecureRandom.generate_bytes(len)
        assert byte_size(bytes) == len
      end
    end
  end

  describe "uniform/2" do
    test "returns value within range for large ranges requiring full bytes" do
      result = SecureRandom.uniform(0, 65535)

      assert result >= 0
      assert result <= 65535
    end

    test "handles single value range" do
      result = SecureRandom.uniform(5, 5)

      assert result == 5
    end

    test "handles zero minimum" do
      result = SecureRandom.uniform(0, 100)

      assert result >= 0
      assert result <= 100
    end

    test "handles large range" do
      result = SecureRandom.uniform(0, 1_000_000)

      assert result >= 0
      assert result <= 1_000_000
    end

    test "generates values across the entire range" do
      results = for _ <- 1..1000, do: SecureRandom.uniform(1, 10)

      # All values 1-10 should appear at least once with 1000 samples
      unique_values = Enum.uniq(results) |> Enum.sort()
      assert length(unique_values) == 10
      assert unique_values == [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
    end

    test "respects minimum bound" do
      results = for _ <- 1..100, do: SecureRandom.uniform(50, 100)

      assert Enum.all?(results, &(&1 >= 50))
    end

    test "respects maximum bound" do
      results = for _ <- 1..100, do: SecureRandom.uniform(1, 50)

      assert Enum.all?(results, &(&1 <= 50))
    end

    test "handles range of 2" do
      results = for _ <- 1..100, do: SecureRandom.uniform(0, 1)

      # Should have both 0 and 1 in results
      assert 0 in results
      assert 1 in results
    end

    test "handles power of 2 ranges" do
      # Range of 256 (2^8)
      results = for _ <- 1..500, do: SecureRandom.uniform(0, 255)

      assert Enum.all?(results, &(&1 >= 0 and &1 <= 255))
      # Should have reasonable distribution
      assert length(Enum.uniq(results)) > 100
    end

    test "handles non-power of 2 ranges" do
      # Range of 7
      results = for _ <- 1..700, do: SecureRandom.uniform(1, 7)

      unique_values = Enum.uniq(results) |> Enum.sort()
      assert unique_values == [1, 2, 3, 4, 5, 6, 7]
    end
  end

  describe "cryptographic properties" do
    test "generates cryptographically unpredictable values" do
      # Generate two sets of values
      set1 = for _ <- 1..100, do: SecureRandom.generate_dhcpv4_xid()
      set2 = for _ <- 1..100, do: SecureRandom.generate_dhcpv4_xid()

      # Sets should be different
      refute set1 == set2
    end

    test "bytes have high entropy" do
      bytes = SecureRandom.generate_bytes(256)

      # Count unique bytes - should have good variety
      unique_bytes = bytes |> :binary.bin_to_list() |> Enum.uniq() |> length()

      # With 256 bytes, we should see a good variety of byte values
      # Statistically we expect ~150-200 unique bytes (birthday paradox)
      assert unique_bytes > 100
    end

    test "consecutive calls produce different results" do
      xid1 = SecureRandom.generate_dhcpv4_xid()
      xid2 = SecureRandom.generate_dhcpv4_xid()

      refute xid1 == xid2
    end
  end

  describe "concurrent usage" do
    test "handles concurrent XID generation" do
      tasks =
        for _ <- 1..50 do
          Task.async(fn -> SecureRandom.generate_dhcpv4_xid() end)
        end

      results = Task.await_many(tasks, 5000)

      # All results should be unique
      assert length(Enum.uniq(results)) == 50
    end

    test "handles concurrent byte generation" do
      tasks =
        for _ <- 1..50 do
          Task.async(fn -> SecureRandom.generate_bytes(32) end)
        end

      results = Task.await_many(tasks, 5000)

      # All results should be unique
      assert length(Enum.uniq(results)) == 50
    end

    test "handles concurrent uniform generation" do
      tasks =
        for _ <- 1..100 do
          Task.async(fn -> SecureRandom.uniform(1, 1_000_000_000) end)
        end

      results = Task.await_many(tasks, 5000)

      # With range of 1B, collision probability is negligible (~5e-6)
      assert length(Enum.uniq(results)) == 100
    end
  end
end
