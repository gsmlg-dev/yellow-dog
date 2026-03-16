defmodule YellowDog.Store.PropertyTest do
  @moduledoc """
  Property-based tests for Store modules.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias YellowDog.Store.{Cache, Key}

  # --- Generators ---

  defp hex_byte do
    gen all(byte <- integer(0x00..0xFF)) do
      byte |> Integer.to_string(16) |> String.pad_leading(2, "0") |> String.downcase()
    end
  end

  defp mac_bytes do
    gen all(bytes <- list_of(hex_byte(), length: 6)) do
      bytes
    end
  end

  defp mac_colon do
    gen all(bytes <- mac_bytes()) do
      Enum.join(bytes, ":")
    end
  end

  defp mac_dash do
    gen all(bytes <- mac_bytes()) do
      Enum.join(bytes, "-")
    end
  end

  defp mac_dot do
    gen all(bytes <- mac_bytes()) do
      Enum.join(bytes, ".")
    end
  end

  defp mac_bare do
    gen all(bytes <- mac_bytes()) do
      Enum.join(bytes, "")
    end
  end

  defp mac_any_format do
    one_of([mac_colon(), mac_dash(), mac_dot(), mac_bare()])
  end

  defp mac_mixed_case do
    gen all(mac <- mac_colon()) do
      mac
      |> String.graphemes()
      |> Enum.map(fn c ->
        if :rand.uniform(2) == 1, do: String.upcase(c), else: c
      end)
      |> Enum.join()
    end
  end

  defp duid_bytes do
    gen all(len <- integer(4..16), bytes <- list_of(hex_byte(), length: len)) do
      bytes
    end
  end

  defp duid_colon do
    gen all(bytes <- duid_bytes()) do
      Enum.join(bytes, ":")
    end
  end

  defp duid_dash do
    gen all(bytes <- duid_bytes()) do
      Enum.join(bytes, "-")
    end
  end

  defp duid_any_format do
    one_of([duid_colon(), duid_dash()])
  end

  defp dns_label do
    gen all(
          len <- integer(1..10),
          chars <- list_of(member_of(Enum.to_list(?a..?z) ++ Enum.to_list(?0..?9)), length: len)
        ) do
      List.to_string(chars)
    end
  end

  defp dns_name do
    gen all(labels <- list_of(dns_label(), min_length: 1, max_length: 4)) do
      Enum.join(labels, ".")
    end
  end

  defp dns_type do
    member_of([:a, :aaaa, :cname, :mx, :ns, :ptr, :srv, :txt, :soa])
  end

  defp service_name do
    member_of([:dns, :dhcpv4, :dhcpv6, :mdns, :netboot, :identity])
  end

  defp config_key do
    member_of([:port, :enabled, :interface, :timeout, :max_retries])
  end

  # --- MAC Normalization Properties ---

  describe "MAC normalization properties" do
    property "any valid MAC format normalizes to lowercase colon-separated" do
      check all(mac <- mac_any_format()) do
        result = Key.normalize_mac(mac)
        assert result =~ ~r/^[0-9a-f]{2}(:[0-9a-f]{2}){5}$/
      end
    end

    property "mixed-case MACs normalize to same canonical form" do
      check all(mac <- mac_mixed_case()) do
        result = Key.normalize_mac(mac)
        assert result == String.downcase(result)
        assert result =~ ~r/^[0-9a-f]{2}(:[0-9a-f]{2}){5}$/
      end
    end

    property "all MAC formats for same bytes produce identical normalized output" do
      check all(bytes <- mac_bytes()) do
        colon = Enum.join(bytes, ":")
        dash = Enum.join(bytes, "-")
        dot = Enum.join(bytes, ".")
        bare = Enum.join(bytes, "")
        upper = String.upcase(colon)

        canonical = Key.normalize_mac(colon)
        assert Key.normalize_mac(dash) == canonical
        assert Key.normalize_mac(dot) == canonical
        assert Key.normalize_mac(bare) == canonical
        assert Key.normalize_mac(upper) == canonical
      end
    end

    property "normalize_mac is idempotent" do
      check all(mac <- mac_any_format()) do
        once = Key.normalize_mac(mac)
        twice = Key.normalize_mac(once)
        assert once == twice
      end
    end
  end

  # --- DUID Normalization Properties ---

  describe "DUID normalization properties" do
    property "any valid DUID format normalizes to lowercase colon-separated" do
      check all(duid <- duid_any_format()) do
        result = Key.normalize_duid(duid)
        assert result == String.downcase(result)
        assert String.contains?(result, ":")
        refute String.contains?(result, "-")
        refute String.contains?(result, ".")
      end
    end

    property "DUID colon and dash formats produce identical output" do
      check all(bytes <- duid_bytes()) do
        colon = Enum.join(bytes, ":")
        dash = Enum.join(bytes, "-")

        assert Key.normalize_duid(colon) == Key.normalize_duid(dash)
      end
    end

    property "normalize_duid is idempotent" do
      check all(duid <- duid_any_format()) do
        once = Key.normalize_duid(duid)
        twice = Key.normalize_duid(once)
        assert once == twice
      end
    end
  end

  # --- Structured Key Encoding Properties ---

  describe "key encoding properties" do
    property "lease_v4 keys always start with lease_v4_prefix" do
      check all(mac <- mac_any_format()) do
        key = Key.lease_v4(mac)
        assert String.starts_with?(key, Key.lease_v4_prefix())
      end
    end

    property "lease_v6 keys always start with lease_v6_prefix" do
      check all(duid <- duid_any_format()) do
        key = Key.lease_v6(duid)
        assert String.starts_with?(key, Key.lease_v6_prefix())
      end
    end

    property "device keys always start with device_prefix" do
      check all(mac <- mac_any_format()) do
        key = Key.device(mac)
        assert String.starts_with?(key, Key.device_prefix())
      end
    end

    property "zone keys always start with zone_prefix" do
      check all(name <- dns_name()) do
        key = Key.zone(name)
        assert String.starts_with?(key, Key.zone_prefix())
      end
    end

    property "zone_rr keys start with zone_rr_prefix for their zone" do
      check all(zone <- dns_name(), owner <- dns_name(), type <- dns_type()) do
        key = Key.zone_rr(zone, owner, type)
        assert String.starts_with?(key, Key.zone_rr_prefix(zone))
      end
    end

    property "cache keys always start with cache_prefix" do
      check all(qname <- dns_name(), qtype <- dns_type()) do
        key = Key.cache(qname, qtype)
        assert String.starts_with?(key, Key.cache_prefix())
      end
    end

    property "rpz keys always start with rpz_prefix for their zone" do
      check all(zone <- dns_name(), trigger <- dns_name()) do
        key = Key.rpz(zone, trigger)
        assert String.starts_with?(key, Key.rpz_prefix(zone))
      end
    end

    property "config keys always start with config_prefix for their service" do
      check all(service <- service_name(), key_name <- config_key()) do
        key = Key.config(service, key_name)
        assert String.starts_with?(key, Key.config_prefix(service))
      end
    end

    property "equivalent MAC inputs produce the same lease key" do
      check all(bytes <- mac_bytes()) do
        colon = Enum.join(bytes, ":")
        bare = Enum.join(bytes, "")

        assert Key.lease_v4(colon) == Key.lease_v4(bare)
        assert Key.device(colon) == Key.device(bare)
      end
    end

    property "different zone names produce different zone keys" do
      check all(z1 <- dns_name(), z2 <- dns_name(), z1 != z2) do
        assert Key.zone(z1) != Key.zone(z2)
      end
    end

    property "all keys are valid UTF-8 strings" do
      check all(mac <- mac_any_format(), name <- dns_name(), type <- dns_type()) do
        keys = [
          Key.lease_v4(mac),
          Key.device(mac),
          Key.zone(name),
          Key.cache(name, type),
          Key.host(name)
        ]

        for key <- keys do
          assert String.valid?(key)
        end
      end
    end
  end

  # --- Cache LRU Properties ---

  describe "cache LRU properties" do
    setup do
      # Clean up any existing table
      if :ets.whereis(:yellow_dog_dns_cache) != :undefined do
        :ets.delete(:yellow_dog_dns_cache)
      end

      Cache.ensure_table()

      on_exit(fn ->
        if :ets.whereis(:yellow_dog_dns_cache) != :undefined do
          :ets.delete(:yellow_dog_dns_cache)
        end
      end)

      :ok
    end

    property "store then lookup returns the same entry" do
      check all(
              label <- dns_label(),
              qtype <- dns_type()
            ) do
        # Ensure clean table for each check
        :ets.delete_all_objects(:yellow_dog_dns_cache)

        qname = "#{label}.prop.test"
        now = System.system_time(:second)

        entry = %{
          rrset: [],
          qname: qname,
          qtype: qtype,
          rcode: :noerror,
          upstream: "8.8.8.8",
          fetched_at: now,
          original_ttl: 3600,
          negative: false
        }

        Cache.store(qname, qtype, entry)
        assert {:ok, ^entry} = Cache.lookup(qname, qtype)
      end
    end

    property "expired entries return :not_found" do
      check all(label <- dns_label()) do
        :ets.delete_all_objects(:yellow_dog_dns_cache)

        qname = "#{label}.expired.test"
        qtype = :a
        past = System.system_time(:second) - 7200

        entry = %{
          rrset: [],
          qname: qname,
          qtype: qtype,
          rcode: :noerror,
          upstream: "8.8.8.8",
          fetched_at: past,
          original_ttl: 3600,
          negative: false
        }

        Cache.store(qname, qtype, entry)
        assert {:error, :not_found} = Cache.lookup(qname, qtype)
      end
    end

    property "stats counters are monotonically non-decreasing across lookups" do
      check all(labels <- list_of(dns_label(), min_length: 1, max_length: 5)) do
        :ets.delete_all_objects(:yellow_dog_dns_cache)

        # Reset counters by reinitializing
        if :ets.whereis(:yellow_dog_dns_cache) != :undefined do
          :ets.delete(:yellow_dog_dns_cache)
        end

        Cache.ensure_table()

        now = System.system_time(:second)
        initial_stats = Cache.stats()
        initial_total = initial_stats.hits + initial_stats.misses

        for label <- labels do
          qname = "#{label}.counter.test"

          entry = %{
            rrset: [],
            qname: qname,
            qtype: :a,
            rcode: :noerror,
            upstream: "8.8.8.8",
            fetched_at: now,
            original_ttl: 3600,
            negative: false
          }

          Cache.store(qname, :a, entry)
          Cache.lookup(qname, :a)
        end

        final_stats = Cache.stats()
        final_total = final_stats.hits + final_stats.misses
        assert final_total >= initial_total + length(labels)
      end
    end
  end
end
