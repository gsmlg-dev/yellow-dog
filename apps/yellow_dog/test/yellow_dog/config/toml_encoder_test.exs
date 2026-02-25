defmodule YellowDog.Config.TomlEncoderTest do
  use ExUnit.Case, async: true

  alias YellowDog.Config.TomlEncoder

  describe "encode/2 - scalar values" do
    test "encodes top-level string" do
      result = TomlEncoder.encode(%{"name" => "yellow-dog"})
      assert result =~ ~s(name = "yellow-dog")
    end

    test "encodes top-level integer" do
      result = TomlEncoder.encode(%{"port" => 53})
      assert result =~ "port = 53"
    end

    test "encodes top-level boolean" do
      result = TomlEncoder.encode(%{"enabled" => true})
      assert result =~ "enabled = true"

      result = TomlEncoder.encode(%{"enabled" => false})
      assert result =~ "enabled = false"
    end

    test "encodes top-level float" do
      result = TomlEncoder.encode(%{"rate" => 1.5})
      assert result =~ "rate = 1.5"
    end

    test "encodes top-level array of strings" do
      result = TomlEncoder.encode(%{"servers" => ["8.8.8.8", "8.8.4.4"]})
      assert result =~ ~s(servers = ["8.8.8.8", "8.8.4.4"])
    end

    test "encodes top-level array of integers" do
      result = TomlEncoder.encode(%{"ports" => [53, 5353]})
      assert result =~ "ports = [53, 5353]"
    end

    test "encodes empty array" do
      result = TomlEncoder.encode(%{"items" => []})
      assert result =~ "items = []"
    end
  end

  describe "encode/2 - string escaping" do
    test "escapes double quotes" do
      result = TomlEncoder.encode(%{"msg" => ~s(say "hello")})
      assert result =~ ~s(msg = "say \\"hello\\"")
    end

    test "escapes backslashes" do
      result = TomlEncoder.encode(%{"path" => "C:\\Users"})
      assert result =~ ~s(path = "C:\\\\Users")
    end

    test "escapes newlines" do
      result = TomlEncoder.encode(%{"text" => "line1\nline2"})
      assert result =~ ~s(text = "line1\\nline2")
    end

    test "escapes tabs" do
      result = TomlEncoder.encode(%{"text" => "col1\tcol2"})
      assert result =~ ~s(text = "col1\\tcol2")
    end
  end

  describe "encode/2 - tables" do
    test "encodes simple table" do
      map = %{"dns" => %{"port" => 53, "listen" => "0.0.0.0"}}
      result = TomlEncoder.encode(map)

      assert result =~ "[dns]"
      assert result =~ ~s(listen = "0.0.0.0")
      assert result =~ "port = 53"
    end

    test "encodes multiple tables" do
      map = %{
        "core" => %{"dns" => true},
        "dns" => %{"port" => 53}
      }

      result = TomlEncoder.encode(map)

      assert result =~ "[core]"
      assert result =~ "dns = true"
      assert result =~ "[dns]"
      assert result =~ "port = 53"
    end

    test "encodes nested tables with dotted keys" do
      map = %{
        "mdns" => %{
          "port" => 5353,
          "services" => %{
            "format" => "toml",
            "auto_save" => true
          }
        }
      }

      result = TomlEncoder.encode(map)

      assert result =~ "[mdns]"
      assert result =~ "port = 5353"
      assert result =~ "[mdns.services]"
      assert result =~ ~s(format = "toml")
      assert result =~ "auto_save = true"
    end

    test "keys are sorted alphabetically" do
      map = %{"zebra" => 1, "alpha" => 2, "middle" => 3}
      result = TomlEncoder.encode(map)

      alpha_pos = :binary.match(result, "alpha") |> elem(0)
      middle_pos = :binary.match(result, "middle") |> elem(0)
      zebra_pos = :binary.match(result, "zebra") |> elem(0)

      assert alpha_pos < middle_pos
      assert middle_pos < zebra_pos
    end

    test "sections are sorted alphabetically" do
      map = %{
        "dns" => %{"port" => 53},
        "core" => %{"dns" => true},
        "mdns" => %{"port" => 5353}
      }

      result = TomlEncoder.encode(map)

      core_pos = :binary.match(result, "[core]") |> elem(0)
      dns_pos = :binary.match(result, "[dns]") |> elem(0)
      mdns_pos = :binary.match(result, "[mdns]") |> elem(0)

      assert core_pos < dns_pos
      assert dns_pos < mdns_pos
    end
  end

  describe "encode/2 - array tables" do
    test "encodes list of maps as array tables" do
      map = %{
        "dhcpv4" => %{
          "port" => 67,
          "pools" => [
            %{"name" => "default", "range_start" => "192.168.1.100"}
          ]
        }
      }

      result = TomlEncoder.encode(map)

      assert result =~ "[dhcpv4]"
      assert result =~ "port = 67"
      assert result =~ "[[dhcpv4.pools]]"
      assert result =~ ~s(name = "default")
      assert result =~ ~s(range_start = "192.168.1.100")
    end

    test "encodes multiple array table entries" do
      map = %{
        "dhcpv4" => %{
          "pools" => [
            %{"name" => "pool1"},
            %{"name" => "pool2"}
          ]
        }
      }

      result = TomlEncoder.encode(map)

      # Should have two [[dhcpv4.pools]] headers
      matches = Regex.scan(~r/\[\[dhcpv4\.pools\]\]/, result)
      assert length(matches) == 2
    end
  end

  describe "encode/2 - options" do
    test "prepends header comment" do
      result = TomlEncoder.encode(%{"port" => 53}, header: "# Yellow Dog DNS Configuration")

      assert String.starts_with?(result, "# Yellow Dog DNS Configuration\n")
    end

    test "no header by default" do
      result = TomlEncoder.encode(%{"port" => 53})
      refute String.starts_with?(result, "#")
    end
  end

  describe "encode/2 - TOML ordering" do
    test "scalars come before tables" do
      map = %{
        "data_dir" => "data",
        "core" => %{"dns" => true}
      }

      result = TomlEncoder.encode(map)

      data_dir_pos = :binary.match(result, "data_dir") |> elem(0)
      core_pos = :binary.match(result, "[core]") |> elem(0)

      assert data_dir_pos < core_pos
    end

    test "tables come before array tables" do
      map = %{
        "dhcpv4" => %{
          "port" => 67,
          "pools" => [%{"name" => "default"}]
        }
      }

      result = TomlEncoder.encode(map)

      port_pos = :binary.match(result, "port = 67") |> elem(0)
      pools_pos = :binary.match(result, "[[dhcpv4.pools]]") |> elem(0)

      assert port_pos < pools_pos
    end
  end

  describe "round-trip: encode → decode" do
    test "round-trips simple config" do
      original = %{
        "core" => %{"dns" => true, "mdns" => false},
        "dns" => %{"listen" => "0.0.0.0", "port" => 53}
      }

      encoded = TomlEncoder.encode(original)
      {:ok, decoded} = Toml.decode(encoded)

      assert decoded == original
    end

    test "round-trips config with array tables" do
      original = %{
        "dhcpv4" => %{
          "listen" => "0.0.0.0",
          "port" => 67,
          "pools" => [
            %{
              "name" => "default",
              "range_start" => "192.168.1.100",
              "range_end" => "192.168.1.200",
              "lease_time" => 3600,
              "gateway" => "192.168.1.1",
              "dns_servers" => ["8.8.8.8", "8.8.4.4"]
            }
          ]
        }
      }

      encoded = TomlEncoder.encode(original)
      {:ok, decoded} = Toml.decode(encoded)

      assert decoded == original
    end

    test "round-trips full default config" do
      original = YellowDog.Config.Schema.defaults()

      encoded = TomlEncoder.encode(original)
      {:ok, decoded} = Toml.decode(encoded)

      assert decoded == original
    end

    test "round-trips config with nested tables" do
      original = %{
        "mdns" => %{
          "port" => 5353,
          "services" => %{
            "format" => "toml",
            "auto_save" => true
          }
        }
      }

      encoded = TomlEncoder.encode(original)
      {:ok, decoded} = Toml.decode(encoded)

      assert decoded == original
    end

    test "round-trips strings with special characters" do
      original = %{"data_dir" => "/var/lib/yellow-dog/data"}
      encoded = TomlEncoder.encode(original)
      {:ok, decoded} = Toml.decode(encoded)
      assert decoded == original
    end
  end

  describe "encode/2 - empty map" do
    test "encodes empty map" do
      result = TomlEncoder.encode(%{})
      assert result == "\n"
    end
  end
end
