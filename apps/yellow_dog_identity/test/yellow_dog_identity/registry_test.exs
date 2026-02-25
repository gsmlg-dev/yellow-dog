defmodule YellowDogIdentity.RegistryTest do
  use ExUnit.Case

  alias YellowDogIdentity.{Host, Token, Registry}

  @valid_ssh_pubkey "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHUzjC6gKCLjRoHMvMXBx3cCe49wjm69r9B7YBcFcAv1 test@host"
  @valid_age_recipient "age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p"

  setup do
    # Use a unique temp directory for each test
    tmp_dir = Path.join(System.tmp_dir!(), "yd_identity_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    {:ok, pid} = Registry.start_link(data_dir: tmp_dir, name: :"registry_#{:erlang.unique_integer([:positive])}")

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      File.rm_rf!(tmp_dir)
    end)

    %{registry: pid, tmp_dir: tmp_dir}
  end

  defp make_host(hostname \\ "node-01") do
    {:ok, host} =
      Host.new(%{
        hostname: hostname,
        ssh_pubkey: @valid_ssh_pubkey,
        age_recipient: @valid_age_recipient
      })

    host
  end

  describe "host CRUD" do
    test "put and get host", %{registry: pid} do
      host = make_host()
      assert :ok = GenServer.call(pid, {:put_host, host})
      assert {:ok, ^host} = GenServer.call(pid, {:get_host, host.id})
    end

    test "get host by fingerprint", %{registry: pid} do
      host = make_host()
      :ok = GenServer.call(pid, {:put_host, host})
      assert {:ok, ^host} = GenServer.call(pid, {:get_host_by_fingerprint, host.key_fingerprint})
    end

    test "get host by hostname", %{registry: pid} do
      host = make_host("myhost")
      :ok = GenServer.call(pid, {:put_host, host})
      assert {:ok, ^host} = GenServer.call(pid, {:get_host_by_hostname, "myhost"})
    end

    test "list hosts", %{registry: pid} do
      host = make_host()
      :ok = GenServer.call(pid, {:put_host, host})
      hosts = GenServer.call(pid, :list_hosts)
      assert length(hosts) == 1
    end

    test "list hosts by status", %{registry: pid} do
      host = make_host()
      :ok = GenServer.call(pid, {:put_host, host})
      pending = GenServer.call(pid, {:list_hosts_by_status, :pending})
      approved = GenServer.call(pid, {:list_hosts_by_status, :approved})
      assert length(pending) == 1
      assert length(approved) == 0
    end

    test "delete host", %{registry: pid} do
      host = make_host()
      :ok = GenServer.call(pid, {:put_host, host})
      assert :ok = GenServer.call(pid, {:delete_host, host.id})
      assert :not_found = GenServer.call(pid, {:get_host, host.id})
    end

    test "not_found for missing host", %{registry: pid} do
      assert :not_found = GenServer.call(pid, {:get_host, "nonexistent"})
    end

    test "get_host_by_fingerprint returns not_found when index desync (host deleted)", %{
      registry: pid
    } do
      host = make_host()
      :ok = GenServer.call(pid, {:put_host, host})
      fingerprint = host.key_fingerprint

      # Verify it's findable before deletion
      assert {:ok, ^host} = GenServer.call(pid, {:get_host_by_fingerprint, fingerprint})

      # Delete the host — after deletion the fingerprint index entry is also removed
      :ok = GenServer.call(pid, {:delete_host, host.id})

      # Fingerprint lookup must not crash — returns :not_found instead
      assert :not_found = GenServer.call(pid, {:get_host_by_fingerprint, fingerprint})
    end

    test "delete host returns not_found for unknown id", %{registry: pid} do
      assert {:error, :not_found} = GenServer.call(pid, {:delete_host, "does-not-exist"})
    end
  end

  describe "token CRUD" do
    test "put and get token", %{registry: pid} do
      {:ok, token, _raw} = Token.create(%{hostname_pattern: "node-*"})
      assert :ok = GenServer.call(pid, {:put_token, token})
      assert {:ok, ^token} = GenServer.call(pid, {:get_token, token.id})
    end

    test "list tokens", %{registry: pid} do
      {:ok, token, _raw} = Token.create(%{})
      :ok = GenServer.call(pid, {:put_token, token})
      tokens = GenServer.call(pid, :list_tokens)
      assert length(tokens) == 1
    end

    test "delete token", %{registry: pid} do
      {:ok, token, _raw} = Token.create(%{})
      :ok = GenServer.call(pid, {:put_token, token})
      assert :ok = GenServer.call(pid, {:delete_token, token.id})
      assert :not_found = GenServer.call(pid, {:get_token, token.id})
    end

    test "delete token returns not_found for unknown id", %{registry: pid} do
      assert {:error, :not_found} = GenServer.call(pid, {:delete_token, "does-not-exist"})
    end
  end

  describe "TOML persistence" do
    test "hosts survive restart", %{tmp_dir: tmp_dir} do
      name1 = :"persist_test_#{:erlang.unique_integer([:positive])}"
      {:ok, pid1} = Registry.start_link(data_dir: tmp_dir, name: name1)

      host = make_host()
      :ok = GenServer.call(pid1, {:put_host, host})
      GenServer.stop(pid1)

      # Restart with same data_dir
      name2 = :"persist_test_#{:erlang.unique_integer([:positive])}"
      {:ok, pid2} = Registry.start_link(data_dir: tmp_dir, name: name2)

      assert {:ok, restored} = GenServer.call(pid2, {:get_host, host.id})
      assert restored.hostname == host.hostname
      assert restored.key_fingerprint == host.key_fingerprint

      GenServer.stop(pid2)
    end

    test "TOML files exist on disk after put", %{tmp_dir: tmp_dir, registry: pid} do
      host = make_host()
      :ok = GenServer.call(pid, {:put_host, host})

      host_file = Path.join([tmp_dir, "hosts", "#{host.id}.toml"])
      assert File.exists?(host_file)

      content = File.read!(host_file)
      assert content =~ "hostname"
      assert content =~ host.hostname
    end
  end
end
