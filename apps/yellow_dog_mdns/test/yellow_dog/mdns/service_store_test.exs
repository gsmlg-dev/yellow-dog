defmodule YellowDog.Mdns.ServiceStoreTest do
  use ExUnit.Case, async: true

  alias YellowDog.Mdns.ServiceStore

  @moduletag :tmp_dir

  describe "load_services/2" do
    test "loads services from TOML file", %{tmp_dir: tmp_dir} do
      toml_content = """
      [[service]]
      name = "Web Server"
      type = "_http._tcp"
      port = 8080
      enabled = true

        [service.txt]
        path = "/api"
        version = "1.0"

        [service.addresses]
        ipv4 = ["192.168.1.100"]
      """

      file_path = Path.join(tmp_dir, "services.toml")
      File.write!(file_path, toml_content)

      assert {:ok, services} = ServiceStore.load_services(file_path)
      assert length(services) == 1

      service = hd(services)
      assert service.name == "Web Server"
      assert service.type == "_http._tcp"
      assert service.port == 8080
      assert service.txt == %{"path" => "/api", "version" => "1.0"}
      assert service.addresses == ["192.168.1.100"]
      assert service.enabled == true
    end

    test "loads services from JSON file", %{tmp_dir: tmp_dir} do
      json_content = """
      {
        "services": [
          {
            "name": "SSH Server",
            "type": "_ssh._tcp",
            "port": 22,
            "enabled": true,
            "addresses": ["192.168.1.100", "fe80::1"]
          }
        ]
      }
      """

      file_path = Path.join(tmp_dir, "services.json")
      File.write!(file_path, json_content)

      assert {:ok, services} = ServiceStore.load_services(file_path)
      assert length(services) == 1

      service = hd(services)
      assert service.name == "SSH Server"
      assert service.type == "_ssh._tcp"
      assert service.port == 22
      assert service.addresses == ["192.168.1.100", "fe80::1"]
    end

    test "handles missing file gracefully", %{tmp_dir: tmp_dir} do
      file_path = Path.join(tmp_dir, "nonexistent.toml")
      assert {:ok, []} = ServiceStore.load_services(file_path)
    end

    test "handles invalid TOML", %{tmp_dir: tmp_dir} do
      invalid_toml = "this is not valid TOML [["

      file_path = Path.join(tmp_dir, "invalid.toml")
      File.write!(file_path, invalid_toml)

      assert {:error, _reason} = ServiceStore.load_services(file_path)
    end

    test "filters out invalid services", %{tmp_dir: tmp_dir} do
      toml_content = """
      [[service]]
      name = "Valid Service"
      type = "_http._tcp"
      port = 8080

      [[service]]
      name = "Invalid Service"
      # Missing type and port
      """

      file_path = Path.join(tmp_dir, "mixed.toml")
      File.write!(file_path, toml_content)

      assert {:ok, services} = ServiceStore.load_services(file_path)
      assert length(services) == 1
      assert hd(services).name == "Valid Service"
    end

    test "handles nested addresses structure", %{tmp_dir: tmp_dir} do
      toml_content = """
      [[service]]
      name = "Multi-address Service"
      type = "_http._tcp"
      port = 8080

        [service.addresses]
        ipv4 = ["192.168.1.100", "192.168.1.101"]
        ipv6 = ["fe80::1", "fe80::2"]
      """

      file_path = Path.join(tmp_dir, "services.toml")
      File.write!(file_path, toml_content)

      assert {:ok, services} = ServiceStore.load_services(file_path)
      service = hd(services)

      assert length(service.addresses) == 4
      assert "192.168.1.100" in service.addresses
      assert "fe80::1" in service.addresses
    end

    test "loads legacy TOML with representable non-string TXT values", %{tmp_dir: tmp_dir} do
      toml_content = """
      [[service]]
      name = "Legacy"
      type = "_legacy._tcp"
      port = 9090

        [service.txt]
        attempts = 3
        advertised = true
        weights = [1, 2]
      """

      file_path = Path.join(tmp_dir, "legacy.toml")
      File.write!(file_path, toml_content)

      assert {:ok, [service]} = ServiceStore.load_services(file_path)

      assert service.txt == %{
               "advertised" => true,
               "attempts" => 3,
               "weights" => [1, 2]
             }
    end
  end

  describe "save_services/3" do
    test "saves services to TOML file", %{tmp_dir: tmp_dir} do
      services = [
        %{
          name: "Test Service",
          type: "_test._tcp",
          port: 9999,
          txt: %{"key" => "value"},
          addresses: ["192.168.1.100"],
          enabled: true
        }
      ]

      file_path = Path.join(tmp_dir, "output.toml")

      assert :ok = ServiceStore.save_services(file_path, services)
      assert File.exists?(file_path)

      # Verify we can load it back
      assert {:ok, loaded} = ServiceStore.load_services(file_path)
      assert length(loaded) == 1
      assert hd(loaded).name == "Test Service"
    end

    test "saves services to JSON file", %{tmp_dir: tmp_dir} do
      services = [
        %{
          name: "Test Service",
          type: "_test._tcp",
          port: 9999,
          enabled: true
        }
      ]

      file_path = Path.join(tmp_dir, "output.json")

      assert :ok = ServiceStore.save_services(file_path, services, format: :json)
      assert File.exists?(file_path)

      # Verify we can load it back
      assert {:ok, loaded} = ServiceStore.load_services(file_path)
      assert length(loaded) == 1
    end

    test "creates backup of existing file", %{tmp_dir: tmp_dir} do
      file_path = Path.join(tmp_dir, "services.toml")
      backup_path = file_path <> ".backup"

      # Create initial file
      File.write!(file_path, "[[service]]\nname = \"Old\"\ntype = \"_old._tcp\"\nport = 8080")

      services = [
        %{name: "New", type: "_new._tcp", port: 9090, enabled: true}
      ]

      assert :ok = ServiceStore.save_services(file_path, services)
      assert File.exists?(backup_path)

      # Verify backup contains old data
      assert {:ok, backup_content} = File.read(backup_path)
      assert backup_content =~ "Old"
    end

    test "performs atomic write", %{tmp_dir: tmp_dir} do
      file_path = Path.join(tmp_dir, "atomic.toml")
      tmp_path = file_path <> ".tmp"

      services = [%{name: "Test", type: "_test._tcp", port: 8080, enabled: true}]

      assert :ok = ServiceStore.save_services(file_path, services)
      # Temp file should be cleaned up
      refute File.exists?(tmp_path)
      assert File.exists?(file_path)
    end

    test "preserves legacy representable non-string TXT values", %{tmp_dir: tmp_dir} do
      file_path = Path.join(tmp_dir, "legacy.toml")

      service = %{
        name: "Legacy",
        type: "_legacy._tcp",
        port: 9090,
        txt: %{"advertised" => true, "attempts" => 3, "weights" => [1, 2]}
      }

      assert :ok = ServiceStore.save_services(file_path, [service])
      assert {:ok, [loaded]} = ServiceStore.load_services(file_path)
      assert loaded.txt == service.txt
    end
  end

  describe "validate_service/1" do
    test "validates service with all required fields" do
      service = %{
        name: "Valid Service",
        type: "_http._tcp",
        port: 8080
      }

      assert :ok = ServiceStore.validate_service(service)
    end

    test "rejects service with missing name" do
      service = %{type: "_http._tcp", port: 8080}
      assert {:error, reason} = ServiceStore.validate_service(service)
      assert reason =~ "name"
    end

    test "rejects service with missing type" do
      service = %{name: "Test", port: 8080}
      assert {:error, reason} = ServiceStore.validate_service(service)
      assert reason =~ "type"
    end

    test "rejects service with missing port" do
      service = %{name: "Test", type: "_http._tcp"}
      assert {:error, reason} = ServiceStore.validate_service(service)
      assert reason =~ "port"
    end

    test "rejects service with invalid name" do
      service = %{name: "", type: "_http._tcp", port: 8080}
      assert {:error, _reason} = ServiceStore.validate_service(service)
    end

    test "rejects service with invalid type" do
      service = %{name: "Test", type: "http", port: 8080}
      assert {:error, reason} = ServiceStore.validate_service(service)
      assert reason =~ "type must start with"
    end

    test "rejects service with invalid port" do
      service = %{name: "Test", type: "_http._tcp", port: 99999}
      assert {:error, reason} = ServiceStore.validate_service(service)
      assert reason =~ "Port"
    end

    test "rejects service with invalid IP addresses" do
      service = %{
        name: "Test",
        type: "_http._tcp",
        port: 8080,
        addresses: ["not-an-ip"]
      }

      assert {:error, reason} = ServiceStore.validate_service(service)
      assert reason =~ "Invalid IP"
    end

    test "accepts service with valid IPv4 addresses" do
      service = %{
        name: "Test",
        type: "_http._tcp",
        port: 8080,
        addresses: ["192.168.1.1", "10.0.0.1"]
      }

      assert :ok = ServiceStore.validate_service(service)
    end

    test "accepts service with valid IPv6 addresses" do
      service = %{
        name: "Test",
        type: "_http._tcp",
        port: 8080,
        addresses: ["fe80::1", "2001:db8::1"]
      }

      assert :ok = ServiceStore.validate_service(service)
    end

    test "accepts service with TXT records" do
      service = %{
        name: "Test",
        type: "_http._tcp",
        port: 8080,
        txt: %{"key" => "value", "version" => "1.0"}
      }

      assert :ok = ServiceStore.validate_service(service)
    end
  end

  describe "control persistence" do
    test "keeps the control TXT contract string-only" do
      service = %{
        name: "Control",
        type: "_control._tcp",
        port: 8080,
        txt: %{"key" => "value"}
      }

      assert :ok = ServiceStore.validate_control_service(service)

      assert {:error, reason} =
               ServiceStore.validate_control_service(%{service | txt: %{"attempts" => 3}})

      assert reason =~ "string keys and values"
    end

    test "round-trips exact control TXT keys and values through TOML", %{tmp_dir: tmp_dir} do
      file_path = Path.join(tmp_dir, "control.toml")

      txt = %{
        "a.b" => "dotted",
        "quote\"key" => "quote\"value",
        "slash\\key" => "slash\\value",
        "newline\nkey" => "line one\nline two",
        "tab\tkey" => "left\tright",
        "return\rkey" => "left\rright"
      }

      service = %{
        name: "Control",
        type: "_control._tcp",
        port: 8080,
        txt: txt,
        enabled: true
      }

      assert :ok = ServiceStore.save_control_services(file_path, [service])
      assert {:ok, [loaded]} = ServiceStore.load_services(file_path)
      assert loaded.txt == txt
    end
  end

  describe "format detection" do
    test "auto-detects TOML from extension", %{tmp_dir: tmp_dir} do
      toml_path = Path.join(tmp_dir, "test.toml")
      services = [%{name: "Test", type: "_test._tcp", port: 8080, enabled: true}]

      :ok = ServiceStore.save_services(toml_path, services)
      {:ok, content} = File.read(toml_path)
      # TOML should contain [[service]]
      assert content =~ "[[service]]"
    end

    test "auto-detects JSON from extension", %{tmp_dir: tmp_dir} do
      json_path = Path.join(tmp_dir, "test.json")
      services = [%{name: "Test", type: "_test._tcp", port: 8080, enabled: true}]

      :ok = ServiceStore.save_services(json_path, services)
      {:ok, content} = File.read(json_path)
      # JSON should contain "services"
      assert content =~ "\"services\""
    end

    test "uses explicit format option", %{tmp_dir: tmp_dir} do
      # Save as JSON even though extension is .txt
      txt_path = Path.join(tmp_dir, "test.txt")
      services = [%{name: "Test", type: "_test._tcp", port: 8080, enabled: true}]

      :ok = ServiceStore.save_services(txt_path, services, format: :json)
      {:ok, content} = File.read(txt_path)
      assert content =~ "\"services\""
    end
  end
end
