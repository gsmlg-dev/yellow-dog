defmodule YellowDogIdentity.ControlFacadeTest do
  use ExUnit.Case, async: false

  alias YellowDog.Server.Control.Revision
  alias YellowDog.Server.Control.Identity, as: IdentityControl
  alias YellowDog.Sync.Error
  alias YellowDogIdentity.{Host, Registry, Token}

  defmodule FileOps do
    @moduledoc false

    def ls(context, path), do: invoke(context, :ls, [path])
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

    test "restart load failures are tracked and control host reads fail closed",
         %{tmp_dir: tmp_dir, file_ops: file_ops} do
      host = put_host!("restart-read-failure-host")
      host_path = Path.join([tmp_dir, "hosts", "#{host.id}.toml"])
      persisted = File.read!(host_path)

      failures = [
        {:ls, {:error, {:raw_path, Path.dirname(host_path)}}},
        {:read, {:error, {:raw_path, host_path}}},
        {:read, {:raise, "raw path #{host_path}"}},
        {:read, {:throw, {:raw_path, host_path}}},
        {:read, {:exit, {:raw_path, host_path}}}
      ]

      for {operation, failure} <- failures do
        set_file_failure(file_ops, operation, failure)
        restart_registry!(tmp_dir, file_ops)
        clear_file_failures(file_ops)

        results = [
          YellowDogIdentity.control_list_hosts(),
          YellowDogIdentity.control_host(host.id),
          YellowDogIdentity.control_approve_host(host.id),
          YellowDogIdentity.control_revoke_host(host.id),
          YellowDogIdentity.control_delete_host(host.id)
        ]

        assert results == List.duplicate({:error, :persistence_failed}, 5)
        refute inspect(results) =~ tmp_dir
        assert Registry.list_hosts() == []
        assert Registry.get_host(host.id) == :not_found
        assert File.read!(host_path) == persisted
        assert Process.alive?(Process.whereis(Registry))
      end

      restart_registry!(tmp_dir, file_ops)
      assert {:ok, %{"host_id" => host_id}} = YellowDogIdentity.control_host(host.id)
      assert host_id == host.id
    end

    test "a corrupt snapshot does not become a successful partial control view",
         %{tmp_dir: tmp_dir, file_ops: file_ops} do
      valid_host = put_host!("valid-restart-host")
      corrupt_host = put_host!("corrupt-restart-host")
      corrupt_path = Path.join([tmp_dir, "hosts", "#{corrupt_host.id}.toml"])
      persisted = File.read!(corrupt_path)

      stop_registry()
      File.write!(corrupt_path, "invalid = [")
      start_registry!(tmp_dir, file_ops)

      assert [%Host{id: valid_id}] = Registry.list_hosts()
      assert valid_id == valid_host.id
      assert Registry.get_host(corrupt_host.id) == :not_found

      assert {:error, :persistence_failed} = YellowDogIdentity.control_list_hosts()
      assert {:error, :persistence_failed} = YellowDogIdentity.control_host(valid_host.id)
      assert {:error, :persistence_failed} = YellowDogIdentity.control_host(corrupt_host.id)

      stop_registry()
      File.write!(corrupt_path, persisted)
      start_registry!(tmp_dir, file_ops)

      assert {:ok, hosts} = YellowDogIdentity.control_list_hosts()

      assert Enum.map(hosts, & &1["host_id"]) |> Enum.sort() ==
               Enum.sort([valid_host.id, corrupt_host.id])
    end

    test "a host document renamed away from its canonical filename remains legacy-visible but blocks control",
         %{tmp_dir: tmp_dir, file_ops: file_ops} do
      host = put_host!("renamed-restart-host")
      canonical_path = Path.join([tmp_dir, "hosts", "#{host.id}.toml"])
      renamed_path = Path.join([tmp_dir, "hosts", "renamed-#{host.id}.toml"])
      persisted = File.read!(canonical_path)

      stop_registry()
      File.rename!(canonical_path, renamed_path)
      start_registry!(tmp_dir, file_ops)

      assert [%Host{id: host_id}] = Registry.list_hosts()
      assert host_id == host.id
      assert {:ok, %Host{id: ^host_id, status: :pending}} = Registry.get_host(host.id)

      assert_control_host_persistence_failed(host.id)

      assert File.read!(renamed_path) == persisted
      refute File.exists?(canonical_path)
    end

    test "duplicate durable host IDs remain legacy-visible but block control without deleting either file",
         %{tmp_dir: tmp_dir, file_ops: file_ops} do
      host = put_host!("duplicate-restart-host")
      canonical_path = Path.join([tmp_dir, "hosts", "#{host.id}.toml"])
      duplicate_path = Path.join([tmp_dir, "hosts", "duplicate-#{host.id}.toml"])
      persisted = File.read!(canonical_path)

      stop_registry()
      File.cp!(canonical_path, duplicate_path)
      start_registry!(tmp_dir, file_ops)

      assert [%Host{id: host_id}] = Registry.list_hosts()
      assert host_id == host.id
      assert {:ok, %Host{id: ^host_id, status: :pending}} = Registry.get_host(host.id)

      assert_control_host_persistence_failed(host.id)

      assert File.read!(canonical_path) == persisted
      assert File.read!(duplicate_path) == persisted
    end

    test "a valid TOML host with an invalid status fails closed and cannot be approved",
         %{tmp_dir: tmp_dir, file_ops: file_ops} do
      host = put_host!("invalid-status-restart-host")
      host_path = Path.join([tmp_dir, "hosts", "#{host.id}.toml"])

      stop_registry()

      invalid =
        host_path
        |> File.read!()
        |> String.replace(~s(status = "pending"), ~s(status = "fabricated"))

      File.write!(host_path, invalid)
      start_registry!(tmp_dir, file_ops)

      assert [%Host{id: host_id, status: :pending}] = Registry.list_hosts()
      assert host_id == host.id
      assert {:ok, %Host{id: ^host_id, status: :pending}} = Registry.get_host(host.id)

      assert_control_host_persistence_failed(host.id)
      assert_identity_server_control_apply_failed(host.id)

      assert File.read!(host_path) == invalid
      refute invalid =~ "approved_at"
      refute invalid =~ "approved_by"
    end

    test "all host enums that the legacy parser coerces fail strict recovery",
         %{tmp_dir: tmp_dir, file_ops: file_ops} do
      for {field, valid, legacy_field, legacy_value} <- [
            {"status", "pending", :status, :pending},
            {"trust_level", "unverified", :trust_level, :cloud_verified},
            {"trust_provider", "none", :trust_provider, :dhcp}
          ] do
        host = put_host!("invalid-#{field}-restart-host")
        host_path = Path.join([tmp_dir, "hosts", "#{host.id}.toml"])

        stop_registry()

        invalid =
          host_path
          |> File.read!()
          |> String.replace(~s(#{field} = "#{valid}"), ~s(#{field} = "unknown"))

        File.write!(host_path, invalid)
        start_registry!(tmp_dir, file_ops)

        assert {:ok, legacy_host} = Registry.get_host(host.id)
        assert Map.fetch!(legacy_host, legacy_field) == legacy_value
        assert {:error, :persistence_failed} = YellowDogIdentity.control_list_hosts()

        stop_registry()
        File.rm!(host_path)
        start_registry!(tmp_dir, file_ops)
      end
    end

    test "strict recovery latches missing, unknown, empty, and overlong control fields",
         %{tmp_dir: tmp_dir, file_ops: file_ops} do
      mutations = [
        fn content, host ->
          String.replace(content, ~s(id = "#{host.id}"), ~s(id = ""))
        end,
        fn content, host ->
          String.replace(
            content,
            ~s(id = "#{host.id}"),
            ~s(id = "#{String.duplicate("x", 129)}")
          )
        end,
        fn content, _host ->
          String.replace(content, ~s(hostname = "strict-schema-host"), ~s(hostname = ""))
        end,
        fn content, _host ->
          String.replace(
            content,
            ~s(hostname = "strict-schema-host"),
            ~s(hostname = "#{String.duplicate("x", 1_025)}")
          )
        end,
        fn content, _host ->
          String.replace(content, "[host]\n", "[host]\nunexpected = \"value\"\n")
        end,
        fn content, _host ->
          String.replace(content, ~r/^created_at = .*\n/m, "")
        end
      ]

      for mutate <- mutations do
        host = put_host!("strict-schema-host")
        host_path = Path.join([tmp_dir, "hosts", "#{host.id}.toml"])

        stop_registry()
        invalid = host_path |> File.read!() |> mutate.(host)
        File.write!(host_path, invalid)
        start_registry!(tmp_dir, file_ops)

        assert [%Host{} = legacy_host] = Registry.list_hosts()
        assert {:ok, ^legacy_host} = Registry.get_host(legacy_host.id)
        assert {:error, :persistence_failed} = YellowDogIdentity.control_list_hosts()

        stop_registry()
        File.rm!(host_path)
        start_registry!(tmp_dir, file_ops)
      end
    end

    test "approval snapshots are deterministic projections of durable host state" do
      pending = put_host!("pending-approval-host")
      approved = put_host!("approved-approval-host")

      assert {:ok, _prior, _resulting} =
               YellowDogIdentity.control_approve_host(approved.id)

      assert {:ok, approvals} = YellowDogIdentity.control_list_approvals()

      assert Enum.map(approvals, & &1["host_id"]) |> Enum.sort() ==
               Enum.sort([pending.id, approved.id])

      assert Enum.all?(approvals, fn approval ->
               Map.keys(approval) |> Enum.sort() == ~w(approval_id host_id state) and
                 approval["approval_id"] =~ ~r/\Aapproval-[0-9a-f]{64}\z/
             end)

      assert %{"state" => "pending"} =
               Enum.find(approvals, &(&1["host_id"] == pending.id))

      assert %{"state" => "approved"} =
               Enum.find(approvals, &(&1["host_id"] == approved.id))
    end

    test "unique audit snapshots are deterministic, bounded, and omit raw details" do
      for index <- 1..105 do
        Registry.append_audit("host.registered", "host-#{index}", %{
          secret: "raw-detail-#{index}"
        })
      end

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
      refute encoded =~ "details"
    end

    test "duplicate canonical audit IDs spanning the public bound fail closed", %{
      tmp_dir: tmp_dir
    } do
      audit_path = Path.join(tmp_dir, "audit.log")
      duplicate = "2026-07-17T00:00:00Z host.registered host=duplicate-audit-host"

      unique_entries =
        for index <- 1..99 do
          "2026-07-17T00:00:00Z host.registered host=unique-audit-host-#{index}"
        end

      File.write!(
        audit_path,
        Enum.join([duplicate | unique_entries] ++ [duplicate], "\n") <> "\n"
      )

      assert {:ok, strict_entries} = Registry.control_read_audit_log(limit: :all)
      assert length(strict_entries) == 101

      assert {:error, :persistence_failed} = YellowDogIdentity.control_list_audit()
    end

    test "audit read failures are typed while legacy reads remain best effort",
         %{tmp_dir: tmp_dir, file_ops: file_ops} do
      assert {:ok, []} = YellowDogIdentity.control_list_audit()

      Registry.append_audit("host.registered", "audit-read-host", %{secret: "hidden"})
      flush_registry()

      audit_path = Path.join(tmp_dir, "audit.log")

      failures = [
        {:error, {:raw_path, audit_path}},
        {:raise, "raw path #{audit_path}"},
        {:throw, {:raw_path, audit_path}},
        {:exit, {:raw_path, audit_path}}
      ]

      for failure <- failures do
        set_file_failure(file_ops, :read, failure)

        result = YellowDogIdentity.control_list_audit()
        assert result == {:error, :persistence_failed}
        refute inspect(result) =~ audit_path
        assert Registry.read_audit_log() == []
        assert YellowDogIdentity.audit_log() == []
        assert Process.alive?(Process.whereis(Registry))

        clear_file_failures(file_ops)
      end

      assert {:ok, [%{"subject_id" => "audit-read-host"}]} =
               YellowDogIdentity.control_list_audit()
    end

    test "audit parse exceptions return a typed control error",
         %{tmp_dir: tmp_dir} do
      audit_path = Path.join(tmp_dir, "audit.log")
      File.write!(audit_path, <<255>>)

      assert {:error, :persistence_failed} = YellowDogIdentity.control_list_audit()
      assert Registry.read_audit_log() == []
      assert YellowDogIdentity.audit_log() == []
      assert Process.alive?(Process.whereis(Registry))
    end

    test "valid UTF-8 garbage fails the entire strict audit read",
         %{tmp_dir: tmp_dir} do
      audit_path = Path.join(tmp_dir, "audit.log")
      File.write!(audit_path, "this is not an audit record\n")

      assert {:error, :persistence_failed} = Registry.control_read_audit_log()

      result = YellowDogIdentity.control_list_audit()
      assert result == {:error, :persistence_failed}
      refute inspect(result) =~ audit_path
      assert Registry.read_audit_log() == []
      assert YellowDogIdentity.audit_log() == []
      assert Process.alive?(Process.whereis(Registry))
    end

    test "a mixed valid and malformed log returns no partial control result",
         %{tmp_dir: tmp_dir} do
      audit_path = Path.join(tmp_dir, "audit.log")

      File.write!(
        audit_path,
        """
        2024-01-01T00:00:00Z host.registered host=valid-audit-host
        malformed durable audit record
        """
      )

      assert {:error, :persistence_failed} = Registry.control_read_audit_log()

      result = YellowDogIdentity.control_list_audit()
      assert result == {:error, :persistence_failed}
      refute inspect(result) =~ "valid-audit-host"
      assert [%{host_id: "valid-audit-host"}] = Registry.read_audit_log()
      assert Process.alive?(Process.whereis(Registry))
    end

    test "grammar-valid records must produce strict public owner records",
         %{tmp_dir: tmp_dir} do
      audit_path = Path.join(tmp_dir, "audit.log")

      invalid_records = [
        "2024-01-01T00:00:00Z unsupported.action host=unsupported-action",
        "not-a-timestamp host.registered host=invalid-timestamp",
        "2024-01-01T00:00:00Z host.registered host=#{String.duplicate("x", 129)}"
      ]

      for record <- invalid_records do
        File.write!(audit_path, record <> "\n")

        result = YellowDogIdentity.control_list_audit()
        assert result == {:error, :persistence_failed}
        refute inspect(result) =~ record
        assert [_legacy_entry] = Registry.read_audit_log()
        assert Process.alive?(Process.whereis(Registry))
      end
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

    test "legacy host and token deletes remain best effort when file removal fails",
         %{tmp_dir: tmp_dir, file_ops: file_ops} do
      host = put_host!("legacy-delete-host")
      {:ok, token, _raw_token} = Token.create(%{})
      :ok = Registry.put_token(token)

      host_path = Path.join([tmp_dir, "hosts", "#{host.id}.toml"])
      token_path = Path.join([tmp_dir, "tokens", "#{token.id}.toml"])

      set_file_failure(file_ops, :rm, {:error, :eacces})

      assert :ok = Registry.delete_host(host.id)
      assert :ok = Registry.delete_token(token.id)
      assert Registry.get_host(host.id) == :not_found
      assert Registry.get_token(token.id) == :not_found
      assert File.exists?(host_path)
      assert File.exists?(token_path)
    end

    test "legacy host writes preserve the underlying filesystem error",
         %{tmp_dir: tmp_dir, file_ops: file_ops} do
      {:ok, host} =
        Host.new(%{
          hostname: "legacy-write-host",
          ssh_pubkey: @valid_key,
          age_recipient: @valid_age
        })

      tmp_path = Path.join([tmp_dir, "hosts", "#{host.id}.toml.tmp"])
      set_file_failure(file_ops, :write, {:error, {:raw_path, tmp_path}})

      assert {:error, {:raw_path, ^tmp_path}} = Registry.put_host(host)
      assert Registry.get_host(host.id) == :not_found
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

  describe "durable token control" do
    test "create returns the secret once and every persisted/read snapshot is redacted",
         %{tmp_dir: tmp_dir, file_ops: file_ops} do
      payload = %{"token_id" => "token-control-1", "label" => "bootstrap", "expires_at" => nil}

      assert {:ok, public, raw_token, nil} = YellowDogIdentity.control_create_token(payload)

      assert public == %{
               "token_id" => "token-control-1",
               "label" => "bootstrap",
               "state" => "active"
             }

      token_path = Path.join([tmp_dir, "tokens", "token-control-1.toml"])
      persisted = File.read!(token_path)
      refute persisted =~ raw_token
      refute inspect(public) =~ raw_token
      refute inspect(public) =~ "token_hash"

      assert {:ok, [^public]} = YellowDogIdentity.control_list_tokens()
      assert {:ok, ^public} = YellowDogIdentity.control_token("token-control-1")

      restart_registry!(tmp_dir, file_ops)

      assert {:ok, [^public]} = YellowDogIdentity.control_list_tokens()
      assert {:ok, ^public} = YellowDogIdentity.control_token("token-control-1")
      refute File.read!(token_path) =~ raw_token
    end

    test "duplicate IDs conflict without replacing the original secret" do
      payload = %{"token_id" => "token-duplicate", "label" => "original", "expires_at" => nil}
      assert {:ok, original, raw_token, nil} = YellowDogIdentity.control_create_token(payload)

      assert {:error, :conflict} =
               YellowDogIdentity.control_create_token(%{payload | "label" => "replacement"})

      assert {:ok, ^original} = YellowDogIdentity.control_token("token-duplicate")
      assert {:ok, consumed} = Registry.consume_token(raw_token, "any-host")
      assert consumed.id == "token-duplicate"
    end

    test "create preserves the validated expiry representation in its one-time result" do
      expires_at = "2030-01-01T00:00:00+00:00"

      assert {:ok, public, _raw_token, ^expires_at} =
               YellowDogIdentity.control_create_token(%{
                 "token_id" => "token-expiry-format",
                 "label" => "formatted",
                 "expires_at" => expires_at
               })

      assert public["state"] == "active"
    end

    test "an already-expired credential is created without leaving an unreported token" do
      expires_at = "2000-01-01T00:00:00Z"

      assert {:ok, expired, raw_token, ^expires_at} =
               YellowDogIdentity.control_create_token(%{
                 "token_id" => "token-created-expired",
                 "label" => "expired",
                 "expires_at" => expires_at
               })

      assert expired["state"] == "expired"
      refute inspect(expired) =~ raw_token
      assert {:ok, ^expired} = YellowDogIdentity.control_token("token-created-expired")
    end

    test "revoke persists a public revoked snapshot instead of deleting the credential",
         %{tmp_dir: tmp_dir, file_ops: file_ops} do
      payload = %{"token_id" => "token-revoke", "label" => "automation", "expires_at" => nil}
      assert {:ok, active, raw_token, nil} = YellowDogIdentity.control_create_token(payload)

      assert {:ok, ^active, revoked} =
               YellowDogIdentity.control_revoke_token("token-revoke")

      assert revoked == %{
               "token_id" => "token-revoke",
               "label" => "automation",
               "state" => "revoked"
             }

      assert {:error, :token_revoked} = Registry.consume_token(raw_token, "any-host")

      restart_registry!(tmp_dir, file_ops)
      assert {:ok, ^revoked} = YellowDogIdentity.control_token("token-revoke")

      assert {:error, :already_revoked} =
               YellowDogIdentity.control_revoke_token("token-revoke")
    end

    test "exhausted and expired tokens are exposed only as expired" do
      {:ok, exhausted, raw_token} = Token.create(%{id: "token-exhausted", label: "exhausted"})
      :ok = Registry.put_token(exhausted)
      assert {:ok, _used} = Registry.consume_token(raw_token, "host")

      {:ok, expired, _raw_token} =
        Token.create(%{
          id: "token-expired",
          label: "expired",
          expires_at: DateTime.add(DateTime.utc_now(), -1, :second)
        })

      :ok = Registry.put_token(expired)

      assert {:ok, snapshots} = YellowDogIdentity.control_list_tokens()
      assert Enum.all?(snapshots, &(&1["state"] == "expired"))
      refute inspect(snapshots) =~ "token_hash"
    end

    test "missing Registry failures are sanitized" do
      stop_registry()

      results = [
        YellowDogIdentity.control_list_approvals(),
        YellowDogIdentity.control_list_tokens(),
        YellowDogIdentity.control_token("token-id"),
        YellowDogIdentity.control_create_token(%{
          "token_id" => "token-id",
          "label" => "label",
          "expires_at" => nil
        }),
        YellowDogIdentity.control_revoke_token("token-id"),
        YellowDogIdentity.control_list_policies(),
        YellowDogIdentity.control_update_policies([])
      ]

      assert Enum.all?(results, &(&1 == {:error, :apply_failed}))
    end
  end

  describe "durable policy control" do
    test "updates replace the exact public set and survive restart", %{
      tmp_dir: tmp_dir,
      file_ops: file_ops
    } do
      assert {:ok, []} = YellowDogIdentity.control_list_policies()

      policies = [
        %{"policy_id" => "default", "action" => "require_approval", "enabled" => true}
      ]

      assert {:ok, [], ^policies} = YellowDogIdentity.control_update_policies(policies)
      assert {:ok, ^policies} = YellowDogIdentity.control_list_policies()

      restart_registry!(tmp_dir, file_ops)
      assert {:ok, ^policies} = YellowDogIdentity.control_list_policies()
    end

    test "invalid policy documents do not change durable state" do
      valid = [%{"policy_id" => "default", "action" => "allow", "enabled" => true}]
      assert {:ok, [], ^valid} = YellowDogIdentity.control_update_policies(valid)

      invalid = [%{"policy_id" => "default", "action" => "approve", "enabled" => true}]
      assert {:error, :invalid} = YellowDogIdentity.control_update_policies(invalid)
      assert {:ok, ^valid} = YellowDogIdentity.control_list_policies()
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

  defp assert_control_host_persistence_failed(host_id) do
    assert List.duplicate({:error, :persistence_failed}, 5) == [
             YellowDogIdentity.control_list_hosts(),
             YellowDogIdentity.control_host(host_id),
             YellowDogIdentity.control_approve_host(host_id),
             YellowDogIdentity.control_revoke_host(host_id),
             YellowDogIdentity.control_delete_host(host_id)
           ]
  end

  defp assert_identity_server_control_apply_failed(host_id) do
    previous = Application.get_env(:yellow_dog, IdentityControl)
    Application.delete_env(:yellow_dog, IdentityControl)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:yellow_dog, IdentityControl)
        config -> Application.put_env(:yellow_dog, IdentityControl, config)
      end
    end)

    assert {:error, %Error{code: :apply_failed, details: %{}}} =
             IdentityControl.current(
               "server.identity.hosts.approve",
               %{"host_id" => host_id}
             )

    assert {:error, %Error{code: :apply_failed, details: %{}}} =
             IdentityControl.dispatch(
               "server.identity.hosts.approve",
               %{"host_id" => host_id}
             )
  end
end
