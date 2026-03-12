defmodule YellowDogIdentity.ExportEdgeTest do
  use ExUnit.Case, async: false

  alias YellowDogIdentity.{Host, Registry, Export}

  @valid_ssh_pubkey "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHVyaWVsQGV4YW1wbGUuY29t test@host"
  @age_recipient_a "age1qyqsyqcyq5rqwzqfpg9scrgwpugpzysnzs23v9cfe3eds"
  @age_recipient_b "age1rl8j96hkzsq9xaxywhg8jkre508jsk97k2mthgy0hp4e0"
  @age_recipient_c "age1tg0pqnn22z5e96mzf0jwp4cjaqrkag4xlnvnpf3lca7zv"

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "export_edge_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    # Stop the identity supervisor (which manages Registry) if running
    if sup = Process.whereis(YellowDogIdentity.Supervisor) do
      Supervisor.stop(sup)
    end

    # Stop any pre-existing registry (started by yellow_dog app)
    if pid = Process.whereis(YellowDogIdentity.Registry) do
      GenServer.stop(pid)
    end

    start_supervised!(
      {YellowDogIdentity.Registry, data_dir: tmp_dir, name: YellowDogIdentity.Registry}
    )

    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    %{tmp_dir: tmp_dir}
  end

  defp make_host(hostname, age_recipient, status) do
    {:ok, host} =
      Host.new(%{
        hostname: hostname,
        ssh_pubkey: @valid_ssh_pubkey,
        age_recipient: age_recipient
      })

    case status do
      :approved ->
        %{host | status: :approved, approved_at: DateTime.utc_now(), approved_by: "test"}

      :revoked ->
        %{
          host
          | status: :revoked,
            revoked_at: DateTime.utc_now(),
            revoked_by: "test",
            revoke_reason: "compromised"
        }

      :pending ->
        host
    end
  end

  describe "recipients_yaml/0" do
    test "empty host list produces age: [] output" do
      result = Export.recipients_yaml()
      assert result == "age: []\n"
    end

    test "single approved host produces YAML list with one entry" do
      host = make_host("node-01", @age_recipient_a, :approved)
      :ok = Registry.put_host(host)

      result = Export.recipients_yaml()
      assert result =~ "age:\n"
      assert result =~ "  - #{@age_recipient_a}"
    end

    test "multiple approved hosts all appear in YAML sorted output" do
      host_a = make_host("node-a", @age_recipient_a, :approved)
      host_b = make_host("node-b", @age_recipient_b, :approved)
      host_c = make_host("node-c", @age_recipient_c, :approved)

      :ok = Registry.put_host(host_c)
      :ok = Registry.put_host(host_a)
      :ok = Registry.put_host(host_b)

      result = Export.recipients_yaml()
      assert result =~ @age_recipient_a
      assert result =~ @age_recipient_b
      assert result =~ @age_recipient_c

      # Verify sorted order: recipients should appear in lexicographic order
      lines = String.split(result, "\n", trim: true)
      recipient_lines = Enum.filter(lines, &String.starts_with?(&1, "  - "))
      recipients = Enum.map(recipient_lines, &String.trim_leading(&1, "  - "))
      assert recipients == Enum.sort(recipients)
    end
  end

  describe "recipients_sops/0" do
    test "empty host list produces sops with empty age string" do
      result = Export.recipients_sops()
      assert result == "creation_rules:\n  - age: \"\"\n"
    end

    test "single approved host produces sops with age key in folded block" do
      host = make_host("sops-node", @age_recipient_a, :approved)
      :ok = Registry.put_host(host)

      result = Export.recipients_sops()
      assert result =~ "creation_rules:"
      assert result =~ "- age: >-"
      assert result =~ @age_recipient_a
    end

    test "multiple approved hosts are comma-separated in sops format" do
      host_a = make_host("sops-a", @age_recipient_a, :approved)
      host_b = make_host("sops-b", @age_recipient_b, :approved)

      :ok = Registry.put_host(host_a)
      :ok = Registry.put_host(host_b)

      result = Export.recipients_sops()

      # Both recipients present, comma-separated across lines
      sorted = Enum.sort([@age_recipient_a, @age_recipient_b])
      expected_joined = Enum.join(sorted, ",\n      ")
      assert result =~ expected_joined
    end
  end

  describe "get_approved_recipients/0 filtering" do
    test "pending hosts are excluded from export" do
      pending = make_host("pending-node", @age_recipient_a, :pending)
      :ok = Registry.put_host(pending)

      assert Export.get_approved_recipients() == []
    end

    test "revoked hosts are excluded from export" do
      revoked = make_host("revoked-node", @age_recipient_a, :revoked)
      :ok = Registry.put_host(revoked)

      assert Export.get_approved_recipients() == []
    end

    test "mix of pending, approved, and revoked only exports approved" do
      pending = make_host("pending-host", @age_recipient_a, :pending)
      approved = make_host("approved-host", @age_recipient_b, :approved)
      revoked = make_host("revoked-host", @age_recipient_c, :revoked)

      :ok = Registry.put_host(pending)
      :ok = Registry.put_host(approved)
      :ok = Registry.put_host(revoked)

      recipients = Export.get_approved_recipients()
      assert recipients == [@age_recipient_b]
    end

    test "multiple approved hosts all appear in sorted order" do
      host_c = make_host("host-c", @age_recipient_c, :approved)
      host_a = make_host("host-a", @age_recipient_a, :approved)
      host_b = make_host("host-b", @age_recipient_b, :approved)

      :ok = Registry.put_host(host_c)
      :ok = Registry.put_host(host_a)
      :ok = Registry.put_host(host_b)

      recipients = Export.get_approved_recipients()
      assert length(recipients) == 3
      assert recipients == Enum.sort([@age_recipient_a, @age_recipient_b, @age_recipient_c])
    end

    test "approved host with nil age_recipient is excluded from export" do
      # Construct a host that bypasses validation by directly setting the struct.
      # In practice, Host.new/1 requires a valid age_recipient, but a host loaded
      # from corrupted TOML could theoretically have nil.
      {:ok, host} =
        Host.new(%{
          hostname: "nil-age-host",
          ssh_pubkey: @valid_ssh_pubkey,
          age_recipient: @age_recipient_a
        })

      # Simulate a corrupted host with nil age_recipient
      corrupted = %{
        host
        | status: :approved,
          approved_at: DateTime.utc_now(),
          approved_by: "test",
          age_recipient: nil
      }

      :ok = Registry.put_host(corrupted)

      # nil recipients are filtered out to prevent invalid YAML/SOPS export
      recipients = Export.get_approved_recipients()
      assert recipients == []
      refute nil in recipients
    end
  end
end
