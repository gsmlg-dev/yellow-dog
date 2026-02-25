defmodule YellowDogIdentity.ExportTest do
  use ExUnit.Case

  alias YellowDogIdentity.{Host, Registry, Export}

  @valid_ssh_pubkey "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHUzjC6gKCLjRoHMvMXBx3cCe49wjm69r9B7YBcFcAv1 test@host"
  @valid_age_recipient "age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p"

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "yd_export_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    # Start registry with the default name so Export module can find it
    {:ok, pid} = Registry.start_link(data_dir: tmp_dir)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      File.rm_rf!(tmp_dir)
    end)

    %{registry: pid, tmp_dir: tmp_dir}
  end

  defp make_approved_host(hostname, age_recipient) do
    {:ok, host} =
      Host.new(%{
        hostname: hostname,
        ssh_pubkey: @valid_ssh_pubkey,
        age_recipient: age_recipient
      })

    %{host | status: :approved, approved_at: DateTime.utc_now(), approved_by: "test"}
  end

  describe "recipients_sops/0" do
    test "exports empty sops when no approved hosts" do
      result = Export.recipients_sops()
      assert result =~ "creation_rules:"
    end

    test "exports approved hosts in sops format" do
      host = make_approved_host("node-01", @valid_age_recipient)
      :ok = Registry.put_host(host)

      result = Export.recipients_sops()
      assert result =~ "creation_rules:"
      assert result =~ @valid_age_recipient
    end
  end

  describe "get_approved_recipients/0" do
    test "returns empty list when no approved hosts" do
      assert [] = Export.get_approved_recipients()
    end

    test "returns only approved hosts" do
      {:ok, pending} =
        Host.new(%{
          hostname: "pending-host",
          ssh_pubkey: @valid_ssh_pubkey,
          age_recipient: @valid_age_recipient
        })

      approved = make_approved_host("approved-host", @valid_age_recipient)

      :ok = Registry.put_host(pending)
      :ok = Registry.put_host(approved)

      recipients = Export.get_approved_recipients()
      assert length(recipients) == 1
      assert @valid_age_recipient in recipients
    end
  end
end
