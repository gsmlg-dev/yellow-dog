defmodule YellowDog.Store.HostTest do
  use ExUnit.Case

  alias YellowDog.Store.Host

  @moduletag :store_integration

  @tag :skip
  test "register creates a new host" do
    hostname = "testhost-#{System.unique_integer([:positive])}"

    attrs = %{
      ssh_pubkeys: ["ssh-ed25519 AAAA..."],
      trust_method: :provisioning_token,
      mac: "aa:bb:cc:dd:ee:01"
    }

    assert :ok = Host.register(hostname, attrs)

    {:ok, host} = Host.get(hostname)
    assert host.hostname == hostname
    assert host.ssh_pubkeys == ["ssh-ed25519 AAAA..."]
    assert is_integer(host.registered_at)
    assert is_integer(host.last_attested)
  end

  @tag :skip
  test "register rejects duplicate hostname (CAS)" do
    hostname = "dup-host-#{System.unique_integer([:positive])}"
    attrs = %{ssh_pubkeys: ["key1"]}

    assert :ok = Host.register(hostname, attrs)
    assert {:error, :already_registered} = Host.register(hostname, %{ssh_pubkeys: ["key2"]})
  end

  @tag :skip
  test "update_keys replaces SSH keys" do
    hostname = "keyhost-#{System.unique_integer([:positive])}"
    Host.register(hostname, %{ssh_pubkeys: ["old-key"], pubkeys: ["old-key"]})

    assert :ok = Host.update_keys(hostname, ["new-key-1", "new-key-2"])

    {:ok, host} = Host.get(hostname)
    assert host.pubkeys == ["new-key-1", "new-key-2"]
  end

  @tag :skip
  test "update_keys returns :not_found for unregistered host" do
    assert {:error, :not_found} = Host.update_keys("ghost-host", ["key"])
  end

  @tag :skip
  test "get returns :not_found for unknown hostname" do
    assert {:error, :not_found} = Host.get("nonexistent-host")
  end

  @tag :skip
  test "by_mac finds host by MAC address" do
    hostname = "machost-#{System.unique_integer([:positive])}"
    mac = "11:22:33:44:55:66"
    Host.register(hostname, %{ssh_pubkeys: ["key"], mac: mac})

    {:ok, host} = Host.by_mac(mac)
    assert host != nil
    assert host.hostname == hostname
  end

  @tag :skip
  test "by_mac normalizes MAC format" do
    hostname = "macfmt-#{System.unique_integer([:positive])}"
    Host.register(hostname, %{ssh_pubkeys: ["key"], mac: "aa:bb:cc:dd:ee:ff"})

    {:ok, host} = Host.by_mac("AA-BB-CC-DD-EE-FF")
    assert host != nil
  end

  @tag :skip
  test "attest refreshes attestation timestamp" do
    hostname = "attest-#{System.unique_integer([:positive])}"
    Host.register(hostname, %{ssh_pubkeys: ["key"]})

    {:ok, before} = Host.get(hostname)
    Process.sleep(1100)
    assert :ok = Host.attest(hostname)

    {:ok, after_attest} = Host.get(hostname)
    assert after_attest.last_attested >= before.last_attested
  end

  @tag :skip
  test "attest returns :not_found for unregistered host" do
    assert {:error, :not_found} = Host.attest("unknown-host")
  end
end
