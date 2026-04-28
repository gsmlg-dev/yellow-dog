defmodule YellowDog.Config.SchemaTest do
  use ExUnit.Case, async: true

  alias YellowDog.Config.Schema

  describe "defaults/0" do
    test "returns a map with all required sections" do
      config = Schema.defaults()

      assert is_map(config["core"])
      assert is_map(config["dns"])
      assert is_map(config["mdns"])
      assert is_map(config["dhcpv4"])
      assert is_map(config["dhcpv6"])
    end

    test "core section has service flags" do
      core = Schema.defaults()["core"]

      assert core["dns"] == true
      assert core["mdns"] == true
      assert core["dhcpv4"] == true
      assert core["dhcpv6"] == true
      assert core["netman"] == true
    end

    test "netman section has defaults" do
      netman = Schema.defaults()["netman"]

      assert is_binary(netman["profile_dir"])
      assert is_integer(netman["reconciliation_interval_ms"])
      assert is_binary(netman["socket_path"])
    end

    test "dns section has default listen and port" do
      dns = Schema.defaults()["dns"]

      assert dns["listen"] == "0.0.0.0"
      assert dns["port"] == 53
    end

    test "dhcpv4 section has default pools" do
      dhcpv4 = Schema.defaults()["dhcpv4"]

      assert is_list(dhcpv4["pools"])
      assert length(dhcpv4["pools"]) == 1

      [pool] = dhcpv4["pools"]
      assert pool["name"] == "default"
      assert pool["range_start"] == "192.168.1.100"
    end

    test "dhcpv6 section has default pools" do
      dhcpv6 = Schema.defaults()["dhcpv6"]

      assert is_list(dhcpv6["pools"])
      assert length(dhcpv6["pools"]) == 1

      [pool] = dhcpv6["pools"]
      assert pool["name"] == "default"
      assert pool["range_start"] == "2001:db8::100"
    end

    test "includes data_dir" do
      assert Schema.defaults()["data_dir"] == "data"
    end

    test "netboot TFTP root defaults under the data directory" do
      assert Schema.defaults()["netboot"]["tftp_root"] == "data/netboot/tftp"
    end
  end

  describe "minimal/0" do
    test "all services are disabled" do
      config = Schema.minimal()

      assert config["core"]["dns"] == false
      assert config["core"]["mdns"] == false
      assert config["core"]["dhcpv4"] == false
      assert config["core"]["dhcpv6"] == false
      assert config["core"]["netman"] == false
    end

    test "has listen and port for all services" do
      config = Schema.minimal()

      assert config["dns"]["port"] == 53
      assert config["mdns"]["port"] == 5353
      assert config["dhcpv4"]["port"] == 67
      assert config["dhcpv6"]["port"] == 547
    end

    test "has no pools" do
      config = Schema.minimal()

      refute Map.has_key?(config["dhcpv4"], "pools")
      refute Map.has_key?(config["dhcpv6"], "pools")
    end

    test "netboot TFTP root defaults under the data directory" do
      assert Schema.minimal()["netboot"]["tftp_root"] == "data/netboot/tftp"
    end
  end

  describe "merge_defaults/1" do
    test "fills missing sections" do
      config = %{"core" => %{"dns" => false}}
      merged = Schema.merge_defaults(config)

      # Existing value preserved
      assert merged["core"]["dns"] == false
      # Missing keys in core filled
      assert merged["core"]["mdns"] == true
      # Missing sections filled
      assert merged["dns"]["port"] == 53
      assert merged["dhcpv4"]["port"] == 67
    end

    test "does not overwrite existing values" do
      config = %{
        "dns" => %{"port" => 5353, "listen" => "127.0.0.1"},
        "core" => %{"dns" => false, "mdns" => false, "dhcpv4" => false, "dhcpv6" => false}
      }

      merged = Schema.merge_defaults(config)

      assert merged["dns"]["port"] == 5353
      assert merged["dns"]["listen"] == "127.0.0.1"
      assert merged["core"]["dns"] == false
    end

    test "preserves extra keys not in defaults" do
      config = %{
        "core" => %{"dns" => true},
        "custom" => %{"key" => "value"}
      }

      merged = Schema.merge_defaults(config)

      assert merged["custom"]["key"] == "value"
    end

    test "preserves list values (does not merge lists)" do
      config = %{
        "dhcpv4" => %{
          "pools" => [%{"name" => "custom", "range_start" => "10.0.0.100"}]
        }
      }

      merged = Schema.merge_defaults(config)

      # User's pools preserved, not merged with defaults
      assert length(merged["dhcpv4"]["pools"]) == 1
      assert hd(merged["dhcpv4"]["pools"])["name"] == "custom"
    end

    test "merging empty map returns full defaults" do
      merged = Schema.merge_defaults(%{})
      assert merged == Schema.defaults()
    end
  end

  describe "validate/1" do
    test "valid config returns :ok" do
      assert :ok = Schema.validate(Schema.defaults())
    end

    test "valid minimal config returns :ok" do
      assert :ok = Schema.validate(Schema.minimal())
    end

    test "detects port out of range" do
      config = put_in(Schema.defaults(), ["dns", "port"], 0)
      assert {:error, errors} = Schema.validate(config)
      assert Enum.any?(errors, fn {path, _} -> path == "dns.port" end)
    end

    test "detects port above 65535" do
      config = put_in(Schema.defaults(), ["dns", "port"], 99999)
      assert {:error, errors} = Schema.validate(config)
      assert Enum.any?(errors, fn {path, _} -> path == "dns.port" end)
    end

    test "detects non-integer port" do
      config = put_in(Schema.defaults(), ["dns", "port"], "53")
      assert {:error, errors} = Schema.validate(config)
      assert Enum.any?(errors, fn {path, msg} -> path == "dns.port" and msg =~ "integer" end)
    end

    test "detects invalid IP address" do
      config = put_in(Schema.defaults(), ["dns", "listen"], "not.an.ip")
      assert {:error, errors} = Schema.validate(config)
      assert Enum.any?(errors, fn {path, _} -> path == "dns.listen" end)
    end

    test "accepts valid IPv6 address" do
      config = put_in(Schema.defaults(), ["dhcpv6", "listen"], "::1")
      assert :ok = Schema.validate(config)
    end

    test "detects non-boolean service flag" do
      config = put_in(Schema.defaults(), ["core", "dns"], "yes")
      assert {:error, errors} = Schema.validate(config)
      assert Enum.any?(errors, fn {path, _} -> path == "core.dns" end)
    end

    test "multiple errors reported at once" do
      config =
        Schema.defaults()
        |> put_in(["dns", "port"], 0)
        |> put_in(["dns", "listen"], "bad")
        |> put_in(["core", "dns"], "yes")

      assert {:error, errors} = Schema.validate(config)
      assert length(errors) == 3
    end

    test "missing sections are tolerated" do
      assert :ok = Schema.validate(%{})
    end
  end

  describe "section_comments/0" do
    test "returns comments for known sections" do
      comments = Schema.section_comments()

      assert is_binary(comments["core"])
      assert is_binary(comments["dns"])
      assert comments["core"] =~ "#"
    end
  end
end
