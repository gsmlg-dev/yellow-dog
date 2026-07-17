defmodule YellowDogIdentity.ControlFacadeTest do
  use ExUnit.Case, async: false

  alias YellowDogIdentity.{Host, Registry}

  @valid_key "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBxRhNpqVVPZOFRZNvKGVfCjXN5US8MLXiEy1Ox7xDT6 test@host"
  @valid_age "age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p"
  @control_actor "yellow_dog_server_control"

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "yd_identity_control_#{System.unique_integer([:positive])}"
      )

    YellowDogIdentity.TestHelper.stop_app_identity()
    start_registry!(tmp_dir)

    on_exit(fn ->
      stop_registry()
      File.rm_rf!(tmp_dir)
    end)

    %{tmp_dir: tmp_dir}
  end

  describe "canonical public snapshots" do
    test "host and approval snapshots contain only fixed fields with stable revisions",
         %{tmp_dir: tmp_dir} do
      host =
        put_host!("public-host",
          trust_evidence: %{"authorization" => "secret"},
          metadata: %{"private_key" => "secret"},
          previous_keys: [%{"ssh_pubkey" => "secret"}]
        )

      assert {:ok,
              [
                %{
                  "host_id" => host_id,
                  "name" => "public-host",
                  "state" => "pending",
                  "revision" => revision
                } = snapshot
              ]} = YellowDogIdentity.control_list_hosts()

      assert host_id == host.id
      assert revision =~ ~r/\A[0-9a-f]{64}\z/
      assert Map.keys(snapshot) |> Enum.sort() == ~w(host_id name revision state)

      assert {:ok,
              [
                %{
                  "approval_id" => ^host_id,
                  "host_id" => ^host_id,
                  "state" => "pending"
                }
              ]} = YellowDogIdentity.control_list_approvals()

      restart_registry!(tmp_dir)

      assert {:ok, [^snapshot]} = YellowDogIdentity.control_list_hosts()
      assert {:ok, ^snapshot} = YellowDogIdentity.control_host(host.id)
    end

    test "token snapshots never expose raw tokens or hashes" do
      {:ok, active, raw_token} =
        YellowDogIdentity.create_token(%{
          hostname_pattern: "private-*",
          created_by: "sensitive-actor"
        })

      {:ok, expired, _raw_token} = YellowDogIdentity.create_token(%{ttl_seconds: -1})

      assert {:ok, snapshots} = YellowDogIdentity.control_list_tokens()

      assert snapshots ==
               [
                 %{"token_id" => active.id, "label" => active.id, "state" => "active"},
                 %{"token_id" => expired.id, "label" => expired.id, "state" => "expired"}
               ]
               |> Enum.sort_by(& &1["token_id"])

      encoded = inspect(snapshots)
      refute encoded =~ raw_token
      refute encoded =~ active.token_hash
      refute encoded =~ "hostname_pattern"
      refute encoded =~ "created_by"
      assert Enum.all?(snapshots, &(Map.keys(&1) |> Enum.sort() == ~w(label state token_id)))
    end

    test "audit snapshots are deterministic, bounded, and omit raw details" do
      for index <- 1..105 do
        Registry.append_audit("host.registered", "host-#{index}", %{
          secret: "raw-detail-#{index}"
        })
      end

      Registry.append_audit("unsupported.action", "ignored-host", %{secret: "ignored"})
      flush_registry()

      assert {:ok, entries} = YellowDogIdentity.control_list_audit()
      assert length(entries) == 100
      assert {:ok, ^entries} = YellowDogIdentity.control_list_audit()

      assert Enum.all?(entries, fn entry ->
               Map.keys(entry) |> Enum.sort() ==
                 ~w(action audit_id occurred_at subject_id) and
                 entry["action"] == "host.registered" and
                 entry["audit_id"] =~ ~r/\Aaudit-[0-9a-f]{64}\z/ and
                 match?({:ok, %DateTime{}, 0}, DateTime.from_iso8601(entry["occurred_at"]))
             end)

      encoded = inspect(entries)
      refute encoded =~ "raw-detail"
      refute encoded =~ "ignored-host"
      refute encoded =~ "details"
    end
  end

  describe "serialized host control" do
    test "approve and revoke return prior and resulting public snapshots" do
      host = put_host!("controlled-host")

      assert {:ok, %{"state" => "pending"} = pending, %{"state" => "approved"} = approved} =
               YellowDogIdentity.control_approve_host(host.id)

      assert pending["host_id"] == host.id
      assert approved["host_id"] == host.id
      refute pending["revision"] == approved["revision"]

      assert {:ok, persisted_approved} = Registry.get_host(host.id)
      assert persisted_approved.approved_by == @control_actor

      assert {:ok, ^approved, %{"state" => "revoked"} = revoked} =
               YellowDogIdentity.control_revoke_host(host.id)

      refute approved["revision"] == revoked["revision"]
      assert {:ok, persisted_revoked} = Registry.get_host(host.id)
      assert persisted_revoked.revoked_by == @control_actor
    end

    test "concurrent approvals serialize through the durable owner" do
      host = put_host!("concurrent-host")

      results =
        1..2
        |> Task.async_stream(
          fn _ -> YellowDogIdentity.control_approve_host(host.id) end,
          ordered: false
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert 1 == Enum.count(results, &match?({:ok, _, %{"state" => "approved"}}, &1))
      assert 1 == Enum.count(results, &match?({:error, {:invalid_status, :approved}}, &1))
    end

    test "delete snapshots before durable deletion and returns prior only after success",
         %{tmp_dir: tmp_dir} do
      host = put_host!("delete-host")
      host_path = Path.join([tmp_dir, "hosts", "#{host.id}.toml"])

      assert {:ok, %{"host_id" => host_id, "state" => "pending"} = prior} =
               YellowDogIdentity.control_delete_host(host.id)

      assert host_id == host.id
      assert Map.keys(prior) |> Enum.sort() == ~w(host_id name revision state)
      refute File.exists?(host_path)
      assert {:error, :not_found} = YellowDogIdentity.control_host(host.id)
    end

    test "delete failure returns no snapshot and leaves the host in owner state",
         %{tmp_dir: tmp_dir} do
      host = put_host!("failed-delete-host")
      host_path = Path.join([tmp_dir, "hosts", "#{host.id}.toml"])

      File.rm!(host_path)
      File.mkdir!(host_path)

      assert {:error, _reason} = YellowDogIdentity.control_delete_host(host.id)
      assert {:ok, %{"host_id" => host_id}} = YellowDogIdentity.control_host(host.id)
      assert host_id == host.id
    end
  end

  describe "serialized token revoke" do
    test "returns a revoked public snapshot only after durable deletion", %{tmp_dir: tmp_dir} do
      {:ok, token, raw_token} = YellowDogIdentity.create_token(%{})
      token_path = Path.join([tmp_dir, "tokens", "#{token.id}.toml"])

      assert {:ok, %{"state" => "active"} = prior, %{"state" => "revoked"} = revoked} =
               YellowDogIdentity.control_revoke_token(token.id)

      assert prior["token_id"] == token.id
      assert revoked == %{prior | "state" => "revoked"}
      refute inspect(revoked) =~ raw_token
      refute inspect(revoked) =~ token.token_hash
      refute File.exists?(token_path)
      assert {:error, :not_found} = YellowDogIdentity.control_token(token.id)
      assert {:ok, []} = YellowDogIdentity.control_list_tokens()

      restart_registry!(tmp_dir)
      assert {:ok, []} = YellowDogIdentity.control_list_tokens()
    end

    test "delete failure returns no revoked snapshot and keeps the token active",
         %{tmp_dir: tmp_dir} do
      {:ok, token, _raw_token} = YellowDogIdentity.create_token(%{})
      token_path = Path.join([tmp_dir, "tokens", "#{token.id}.toml"])

      File.rm!(token_path)
      File.mkdir!(token_path)

      assert {:error, _reason} = YellowDogIdentity.control_revoke_token(token.id)

      assert {:ok, %{"token_id" => token_id, "state" => "active"}} =
               YellowDogIdentity.control_token(token.id)

      assert token_id == token.id
    end
  end

  defp put_host!(hostname, overrides \\ []) do
    {:ok, host} =
      Host.new(%{
        hostname: hostname,
        ssh_pubkey: @valid_key,
        age_recipient: @valid_age
      })

    host = struct!(host, overrides)
    :ok = Registry.put_host(host)
    host
  end

  defp restart_registry!(tmp_dir) do
    stop_registry()
    start_registry!(tmp_dir)
  end

  defp start_registry!(tmp_dir) do
    {:ok, _pid} = Registry.start_link(data_dir: tmp_dir, name: Registry)
  end

  defp stop_registry do
    case Process.whereis(Registry) do
      nil ->
        :ok

      pid ->
        try do
          GenServer.stop(pid)
        catch
          :exit, _reason -> :ok
        end
    end
  end

  defp flush_registry, do: :sys.get_state(Registry)
end
