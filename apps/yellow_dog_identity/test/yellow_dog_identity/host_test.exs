defmodule YellowDogIdentity.HostTest do
  use ExUnit.Case, async: true

  alias YellowDogIdentity.Host

  @valid_ssh_pubkey "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHUzjC6gKCLjRoHMvMXBx3cCe49wjm69r9B7YBcFcAv1 test@host"
  @valid_age_recipient "age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p"

  describe "compute_fingerprint/1" do
    test "computes SHA256 fingerprint from valid ed25519 pubkey" do
      assert {:ok, "SHA256:" <> _} = Host.compute_fingerprint(@valid_ssh_pubkey)
    end

    test "returns error for invalid pubkey" do
      assert {:error, :invalid_pubkey} = Host.compute_fingerprint("not a key")
    end
  end

  describe "validate_pubkey/1" do
    test "accepts valid ed25519 pubkey" do
      assert :ok = Host.validate_pubkey(@valid_ssh_pubkey)
    end

    test "rejects invalid key" do
      assert {:error, :invalid_pubkey} = Host.validate_pubkey("bad-key")
    end
  end

  describe "validate_age_recipient/1" do
    test "accepts valid age recipient" do
      assert :ok = Host.validate_age_recipient(@valid_age_recipient)
    end

    test "rejects invalid age recipient" do
      assert {:error, :invalid_age_recipient} = Host.validate_age_recipient("not-age")
    end
  end

  describe "new/1" do
    test "creates host with valid params" do
      params = %{
        hostname: "node-01",
        ssh_pubkey: @valid_ssh_pubkey,
        age_recipient: @valid_age_recipient,
        metadata: %{"role" => "worker"}
      }

      assert {:ok, %Host{} = host} = Host.new(params)
      assert host.hostname == "node-01"
      assert host.status == :pending
      assert host.trust_level == :unverified
      assert host.role == "worker"
      assert String.starts_with?(host.key_fingerprint, "SHA256:")
      assert host.id =~ ~r/^[0-9a-f]{8}-/
    end

    test "accepts machine_id param (dbus machine id)" do
      params = %{
        hostname: "node-02",
        ssh_pubkey: @valid_ssh_pubkey,
        age_recipient: @valid_age_recipient,
        machine_id: "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4"
      }

      assert {:ok, host} = Host.new(params)
      assert host.machine_id == "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4"
    end

    test "machine_id is nil when not provided" do
      params = %{hostname: "node-03", ssh_pubkey: @valid_ssh_pubkey, age_recipient: @valid_age_recipient}
      assert {:ok, host} = Host.new(params)
      assert host.machine_id == nil
    end

    test "creates host with string-key params" do
      params = %{
        "hostname" => "node-02",
        "ssh_pubkey" => @valid_ssh_pubkey,
        "age_recipient" => @valid_age_recipient
      }

      assert {:ok, %Host{hostname: "node-02"}} = Host.new(params)
    end

    test "rejects missing hostname" do
      params = %{ssh_pubkey: @valid_ssh_pubkey, age_recipient: @valid_age_recipient}
      assert {:error, :hostname_required} = Host.new(params)
    end

    test "rejects missing ssh_pubkey" do
      params = %{hostname: "node-01", age_recipient: @valid_age_recipient}
      assert {:error, :ssh_pubkey_required} = Host.new(params)
    end

    test "rejects missing age_recipient" do
      params = %{hostname: "node-01", ssh_pubkey: @valid_ssh_pubkey}
      assert {:error, :age_recipient_required} = Host.new(params)
    end

    test "rejects invalid pubkey format" do
      params = %{
        hostname: "node-01",
        ssh_pubkey: "bad-key",
        age_recipient: @valid_age_recipient
      }

      assert {:error, :invalid_pubkey} = Host.new(params)
    end

    test "rejects hostname exceeding max length" do
      long_hostname = String.duplicate("a", 254)

      params = %{
        hostname: long_hostname,
        ssh_pubkey: @valid_ssh_pubkey,
        age_recipient: @valid_age_recipient
      }

      assert {:error, :hostname_too_long} = Host.new(params)
    end

    test "rejects hostname with newlines" do
      params = %{
        hostname: "node\n-injected",
        ssh_pubkey: @valid_ssh_pubkey,
        age_recipient: @valid_age_recipient
      }

      assert {:error, :hostname_invalid_chars} = Host.new(params)
    end

    test "rejects hostname with spaces" do
      params = %{
        hostname: "node 01",
        ssh_pubkey: @valid_ssh_pubkey,
        age_recipient: @valid_age_recipient
      }

      assert {:error, :hostname_invalid_chars} = Host.new(params)
    end

    test "accepts hostname with dots, hyphens, and underscores" do
      params = %{
        hostname: "node-01.dc1.example_corp",
        ssh_pubkey: @valid_ssh_pubkey,
        age_recipient: @valid_age_recipient
      }

      assert {:ok, %Host{hostname: "node-01.dc1.example_corp"}} = Host.new(params)
    end

    test "accepts hostname at max length boundary" do
      hostname = String.duplicate("a", 253)

      params = %{
        hostname: hostname,
        ssh_pubkey: @valid_ssh_pubkey,
        age_recipient: @valid_age_recipient
      }

      assert {:ok, %Host{}} = Host.new(params)
    end
  end

  describe "to_toml_map/1 and from_toml_map/1" do
    test "round-trips host through TOML map" do
      {:ok, host} =
        Host.new(%{
          hostname: "node-01",
          ssh_pubkey: @valid_ssh_pubkey,
          age_recipient: @valid_age_recipient,
          metadata: %{"role" => "worker"}
        })

      toml_map = Host.to_toml_map(host)
      assert %{"host" => %{"hostname" => "node-01"}} = toml_map

      {:ok, restored} = Host.from_toml_map(toml_map)
      assert restored.hostname == host.hostname
      assert restored.key_fingerprint == host.key_fingerprint
      assert restored.id == host.id
    end

    test "round-trips machine_id through TOML map" do
      {:ok, host} =
        Host.new(%{
          hostname: "machine-node",
          ssh_pubkey: @valid_ssh_pubkey,
          age_recipient: @valid_age_recipient,
          machine_id: "aabbccdd11223344aabbccdd11223344"
        })

      toml_map = Host.to_toml_map(host)
      assert get_in(toml_map, ["host", "machine_id"]) == "aabbccdd11223344aabbccdd11223344"

      {:ok, restored} = Host.from_toml_map(toml_map)
      assert restored.machine_id == "aabbccdd11223344aabbccdd11223344"
    end

    test "machine_id is absent from TOML when nil" do
      {:ok, host} =
        Host.new(%{
          hostname: "no-machine-id-node",
          ssh_pubkey: @valid_ssh_pubkey,
          age_recipient: @valid_age_recipient
        })

      toml_map = Host.to_toml_map(host)
      # nil machine_id should not appear in the TOML map
      refute Map.has_key?(toml_map["host"], "machine_id")

      {:ok, restored} = Host.from_toml_map(toml_map)
      assert restored.machine_id == nil
    end

    test "from_toml_map rejects missing host section" do
      assert {:error, :missing_host_section} = Host.from_toml_map(%{"wrong" => %{}})
    end

    test "from_toml_map returns nil for invalid created_at datetime string" do
      {:ok, host} =
        Host.new(%{
          hostname: "node-01",
          ssh_pubkey: @valid_ssh_pubkey,
          age_recipient: @valid_age_recipient
        })

      toml_map = Host.to_toml_map(host)
      # Corrupt created_at to an invalid ISO8601 string
      corrupted =
        put_in(toml_map, ["host", "created_at"], "not-a-valid-datetime")

      {:ok, restored} = Host.from_toml_map(corrupted)
      # parse_datetime returns nil for unparseable strings (not an error)
      assert is_nil(restored.created_at)
    end

    test "from_toml_map returns invalid_toml_data when required key is missing" do
      # Missing "id" key triggers Map.fetch! KeyError → rescue → {:error, {:invalid_toml_data, _}}
      incomplete = %{
        "host" => %{
          "hostname" => "node-01",
          "ssh_pubkey" => @valid_ssh_pubkey,
          "key_fingerprint" => "SHA256:abc",
          "age_recipient" => @valid_age_recipient,
          "status" => "pending",
          "trust_level" => "unverified",
          "trust_provider" => "unverified"
          # "id" intentionally omitted
        }
      }

      assert {:error, {:invalid_toml_data, _message}} = Host.from_toml_map(incomplete)
    end

    test "round-trips netboot trust_provider correctly" do
      # Regression: netboot was missing from @valid_trust_providers, causing
      # netboot-verified hosts to load back with trust_provider: :dhcp
      {:ok, host} =
        Host.new(%{
          hostname: "netboot-node",
          ssh_pubkey: @valid_ssh_pubkey,
          age_recipient: @valid_age_recipient
        })

      netboot_host = %{host | trust_provider: :netboot, trust_level: :netboot_verified}

      toml_map = Host.to_toml_map(netboot_host)
      {:ok, restored} = Host.from_toml_map(toml_map)

      assert restored.trust_provider == :netboot
      assert restored.trust_level == :netboot_verified
    end

    test "round-trips all valid trust_providers without corruption" do
      {:ok, host} =
        Host.new(%{
          hostname: "trust-round-trip",
          ssh_pubkey: @valid_ssh_pubkey,
          age_recipient: @valid_age_recipient
        })

      providers = [:dhcp, :netboot, :aws, :gcp, :azure, :token, :none]

      for provider <- providers do
        modified = %{host | trust_provider: provider}
        toml_map = Host.to_toml_map(modified)
        {:ok, restored} = Host.from_toml_map(toml_map)
        assert restored.trust_provider == provider, "Expected #{provider} but got #{restored.trust_provider}"
      end
    end
  end
end
