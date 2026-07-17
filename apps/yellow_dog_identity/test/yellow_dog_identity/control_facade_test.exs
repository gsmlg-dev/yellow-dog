defmodule YellowDogIdentity.ControlFacadeTest do
  use ExUnit.Case, async: false

  alias YellowDog.Server.Control.Revision
  alias YellowDogIdentity.{Host, Registry}

  defmodule FileOps do
    @moduledoc false

    def mkdir_p(context, path), do: invoke(context, :mkdir_p, [path])
    def write(context, path, contents), do: invoke(context, :write, [path, contents])
    def read(context, path), do: invoke(context, :read, [path])
    def rename(context, source, destination), do: invoke(context, :rename, [source, destination])
    def rm(context, path), do: invoke(context, :rm, [path])

    defp invoke(context, operation, arguments) do
      case Agent.get(context, &Map.get(&1, operation, :pass)) do
        :pass -> apply(File, operation, arguments)
        {:error, reason} -> {:error, reason}
        {:raise, message} -> raise message
        {:throw, value} -> throw(value)
        {:exit, reason} -> exit(reason)
      end
    end
  end

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
    {:ok, file_ops} = Agent.start_link(fn -> %{} end)
    start_registry!(tmp_dir, file_ops)

    on_exit(fn ->
      stop_registry()
      File.rm_rf!(tmp_dir)
    end)

    %{tmp_dir: tmp_dir, file_ops: file_ops}
  end

  describe "canonical public snapshots" do
    test "host snapshots contain fixed fields and the canonical Server revision",
         %{tmp_dir: tmp_dir, file_ops: file_ops} do
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

      canonical_resource = Map.delete(snapshot, "revision")
      assert {:ok, ^revision} = Revision.calculate(canonical_resource)
      assert {:ok, ^revision} = Revision.calculate(snapshot)

      restart_registry!(tmp_dir, file_ops)

      assert {:ok, [^snapshot]} = YellowDogIdentity.control_list_hosts()
      assert {:ok, ^snapshot} = YellowDogIdentity.control_host(host.id)
    end

    test "approval and token owner surfaces are typed unsupported without an owner" do
      stop_registry()

      assert {:error, :unsupported} = YellowDogIdentity.control_list_approvals()
      assert {:error, :unsupported} = YellowDogIdentity.control_list_tokens()
      assert {:error, :unsupported} = YellowDogIdentity.control_token("token-id")
      assert {:error, :unsupported} = YellowDogIdentity.control_revoke_token("token-id")
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
         %{tmp_dir: tmp_dir, file_ops: file_ops} do
      host = put_host!("failed-delete-host")
      host_path = Path.join([tmp_dir, "hosts", "#{host.id}.toml"])
      persisted = File.read!(host_path)

      set_file_failure(file_ops, :rm, {:error, {:raw_path, host_path}})

      assert {:error, :persistence_failed} =
               YellowDogIdentity.control_delete_host(host.id)

      assert {:ok, %{"host_id" => host_id}} = YellowDogIdentity.control_host(host.id)
      assert host_id == host.id
      assert File.read!(host_path) == persisted
    end

    test "mkdir and write failures are sanitized without changing state or disk",
         %{tmp_dir: tmp_dir, file_ops: file_ops} do
      host = put_host!("failed-write-host")
      host_path = Path.join([tmp_dir, "hosts", "#{host.id}.toml"])
      persisted = File.read!(host_path)

      failures = [
        {:mkdir_p, {:error, {:raw_path, Path.dirname(host_path)}}},
        {:write, {:error, {:raw_path, host_path}}},
        {:write, {:raise, "raw path #{host_path}"}},
        {:write, {:throw, {:raw_path, host_path}}},
        {:write, {:exit, {:raw_path, host_path}}},
        {:rename, {:error, {:raw_path, host_path}}}
      ]

      for {operation, failure} <- failures do
        set_file_failure(file_ops, operation, failure)

        assert {:error, :persistence_failed} =
                 YellowDogIdentity.control_approve_host(host.id)

        assert {:ok, persisted_host} = Registry.get_host(host.id)
        assert persisted_host.status == :pending
        assert File.read!(host_path) == persisted
        assert Process.alive?(Process.whereis(Registry))

        clear_file_failures(file_ops)
      end
    end

    test "delete exceptions are sanitized without changing state or disk",
         %{tmp_dir: tmp_dir, file_ops: file_ops} do
      host = put_host!("failed-delete-exception-host")
      host_path = Path.join([tmp_dir, "hosts", "#{host.id}.toml"])
      persisted = File.read!(host_path)

      failures = [
        {:raise, "raw path #{host_path}"},
        {:throw, {:raw_path, host_path}},
        {:exit, {:raw_path, host_path}}
      ]

      for failure <- failures do
        set_file_failure(file_ops, :rm, failure)

        assert {:error, :persistence_failed} =
                 YellowDogIdentity.control_delete_host(host.id)

        assert {:ok, persisted_host} = Registry.get_host(host.id)
        assert persisted_host.status == :pending
        assert File.read!(host_path) == persisted
        assert Process.alive?(Process.whereis(Registry))

        clear_file_failures(file_ops)
      end
    end

    test "missing Registry exits are mapped to apply_failed" do
      host = put_host!("owner-exit-host")
      stop_registry()

      assert {:error, :apply_failed} = YellowDogIdentity.control_list_hosts()
      assert {:error, :apply_failed} = YellowDogIdentity.control_host(host.id)
      assert {:error, :apply_failed} = YellowDogIdentity.control_approve_host(host.id)
      assert {:error, :apply_failed} = YellowDogIdentity.control_revoke_host(host.id)
      assert {:error, :apply_failed} = YellowDogIdentity.control_delete_host(host.id)
      assert {:error, :apply_failed} = YellowDogIdentity.control_list_audit()
    end
  end

  describe "unsupported token control" do
    test "never exposes or revokes an exhausted persisted token", %{tmp_dir: tmp_dir} do
      {:ok, token, raw_token} =
        YellowDogIdentity.create_token(%{
          hostname_pattern: "*",
          max_uses: 1,
          created_by: "sensitive-actor"
        })

      assert {:ok, exhausted} = Registry.consume_token(raw_token, "host")
      assert exhausted.use_count == exhausted.max_uses

      token_path = Path.join([tmp_dir, "tokens", "#{token.id}.toml"])
      persisted = File.read!(token_path)

      results = [
        YellowDogIdentity.control_list_tokens(),
        YellowDogIdentity.control_token(token.id),
        YellowDogIdentity.control_revoke_token(token.id)
      ]

      assert results == [
               {:error, :unsupported},
               {:error, :unsupported},
               {:error, :unsupported}
             ]

      refute inspect(results) =~ raw_token
      refute inspect(results) =~ token.token_hash
      assert {:ok, ^exhausted} = Registry.get_token(token.id)
      assert File.read!(token_path) == persisted
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

  defp restart_registry!(tmp_dir, file_ops) do
    stop_registry()
    start_registry!(tmp_dir, file_ops)
  end

  defp start_registry!(tmp_dir, file_ops) do
    {:ok, _pid} =
      Registry.start_link(
        data_dir: tmp_dir,
        name: Registry,
        file_ops: {FileOps, file_ops}
      )
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

  defp set_file_failure(file_ops, operation, failure) do
    Agent.update(file_ops, &Map.put(&1, operation, failure))
  end

  defp clear_file_failures(file_ops), do: Agent.update(file_ops, fn _state -> %{} end)

  defp flush_registry, do: :sys.get_state(Registry)
end
