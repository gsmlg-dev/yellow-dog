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

    test "rejects unknown key type" do
      # A key whose type token is not in the allowlist must be rejected
      # regardless of whether the base64 is otherwise valid.
      fake_key =
        "ssh-unknown AAAAC3NzaC1lZDI1NTE5AAAAIHUzjC6gKCLjRoHMvMXBx3cCe49wjm69r9B7YBcFcAv1"

      assert {:error, :invalid_pubkey} = Host.validate_pubkey(fake_key)
    end

    test "rejects key whose wire-format type does not match declared type" do
      # Take a real ed25519 base64 blob but label it as a different type.
      # The embedded wire-format type string is "ssh-ed25519", but the label says "ssh-rsa".
      # The validation must detect the mismatch.
      [_type, b64 | _] = String.split(@valid_ssh_pubkey, " ", parts: 3)
      mismatched = "ssh-rsa " <> b64 <> " test@host"
      assert {:error, :invalid_pubkey} = Host.validate_pubkey(mismatched)
    end

    test "rejects key with valid type token but invalid wire-format (truncated base64)" do
      assert {:error, :invalid_pubkey} = Host.validate_pubkey("ssh-ed25519 bm90YmFzZTY0 comment")
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

    test "rejects invalid pubkey format" do
      params = %{
        hostname: "node-01",
        ssh_pubkey: "bad-key",
        age_recipient: @valid_age_recipient
      }

      assert {:error, :invalid_pubkey} = Host.new(params)
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

    test "from_toml_map rejects missing host section" do
      assert {:error, :missing_host_section} = Host.from_toml_map(%{"wrong" => %{}})
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

        assert restored.trust_provider == provider,
               "Expected #{provider} but got #{restored.trust_provider}"
      end
    end

    test "preserves legacy fallback behavior for unknown enum strings" do
      {:ok, host} =
        Host.new(%{
          hostname: "legacy-enum-fallback",
          ssh_pubkey: @valid_ssh_pubkey,
          age_recipient: @valid_age_recipient
        })

      toml_map =
        update_in(Host.to_toml_map(host)["host"], fn data ->
          %{
            data
            | "status" => "unknown",
              "trust_level" => "unknown",
              "trust_provider" => "unknown"
          }
        end)

      assert {:ok,
              %Host{
                status: :pending,
                trust_level: :cloud_verified,
                trust_provider: :dhcp
              }} = Host.from_toml_map(toml_map)
    end
  end
end
