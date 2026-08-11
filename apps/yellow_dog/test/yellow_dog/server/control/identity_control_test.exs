defmodule YellowDog.Server.Control.IdentityControlTest do
  use ExUnit.Case, async: false

  alias YellowDog.Server.Control.Dispatcher
  alias YellowDog.Server.Control.Identity
  alias YellowDog.Server.Control.Revision
  alias YellowDog.ServerIdentityControlFake
  alias YellowDog.Sync.Bounds
  alias YellowDog.Sync.Digest
  alias YellowDog.Sync.Envelope
  alias YellowDog.Sync.Error
  alias YellowDog.Sync.Operation
  alias YellowDog.Sync.ServerOperation

  @request_id "00000000-0000-0000-0000-00000000007c"
  @idempotency_key "00000000-0000-0000-0000-00000000017c"
  @sent_at ~U[2026-07-17 00:00:00Z]
  @observed_at "2026-07-17T00:00:00Z"

  setup do
    previous_identity = Application.get_env(:yellow_dog, Identity)
    previous_dispatcher = Application.get_env(:yellow_dog, Dispatcher)

    Application.put_env(:yellow_dog, Identity,
      identity: YellowDog.ServerIdentityControlFake.Owner,
      clock: YellowDog.ServerIdentityControlFake.Clock
    )

    Application.put_env(:yellow_dog, Dispatcher,
      adapters: %{identity: Identity},
      service_registry: YellowDog.ServerControlFake.ServiceRegistry,
      profile_resolver: YellowDog.ServerControlFake.ProfileResolver
    )

    start_supervised!(ServerIdentityControlFake)
    start_supervised!(YellowDog.ServerControlFake)

    on_exit(fn ->
      restore_env(Identity, previous_identity)
      restore_env(Dispatcher, previous_dispatcher)
    end)

    :ok
  end

  test "host list is strict, sorted, bounded, revisioned before pagination, and dispatched" do
    hosts =
      for index <- 1..(Bounds.max_list_entries() + 2) do
        host("host-#{String.pad_leading(Integer.to_string(index), 4, "0")}", "pending")
      end
      |> Enum.reverse()

    YellowDog.ServerIdentityControlFake.configure(%{control_list_hosts: {:ok, hosts}})

    assert {:ok, first} =
             Dispatcher.dispatch(
               envelope("server.identity.hosts.list", %{
                 "cursor" => "host-0001",
                 "limit" => 1
               })
             )

    assert first["items"] == [host("host-0002", "pending")]
    assert first["observed_at"] == @observed_at

    bounded = hosts |> Enum.sort_by(& &1["host_id"]) |> Enum.take(Bounds.max_list_entries())
    assert {:ok, revision} = Revision.calculate(bounded)
    assert first["revision"] == revision
    assert_valid_result("server.identity.hosts.list", first)

    invalid_tail =
      List.replace_at(hosts, 0, Map.put(hd(hosts), "token_hash", "raw-token-material"))

    YellowDog.ServerIdentityControlFake.configure(%{
      control_list_hosts: {:ok, invalid_tail}
    })

    result = Identity.dispatch("server.identity.hosts.list", %{"limit" => 1})
    assert_error(:invalid, result)
    refute inspect(result) =~ "raw-token-material"
  end

  test "audit list is strict, sorted, bounded, revisioned, and never exposes details" do
    audits =
      for index <- 1..(Bounds.max_list_entries() + 2) do
        audit(index)
      end
      |> Enum.reverse()

    YellowDog.ServerIdentityControlFake.configure(%{control_list_audit: {:ok, audits}})

    assert {:ok, result} =
             Dispatcher.dispatch(
               envelope("server.identity.audit.list", %{
                 "cursor" => "audit-0001",
                 "limit" => 2
               })
             )

    assert result["items"] == [audit(2), audit(3)]
    assert result["observed_at"] == @observed_at

    bounded = audits |> Enum.sort_by(& &1["audit_id"]) |> Enum.take(Bounds.max_list_entries())
    assert {:ok, revision} = Revision.calculate(bounded)
    assert result["revision"] == revision
    assert_valid_result("server.identity.audit.list", result)
    refute inspect(result) =~ "details"
    refute inspect(result) =~ "secret"

    malformed = Map.put(audit(1), "details", %{"secret" => "audit-secret"})
    YellowDog.ServerIdentityControlFake.configure(%{control_list_audit: {:ok, [malformed]}})

    rejected = Identity.dispatch("server.identity.audit.list", %{})
    assert_error(:invalid, rejected)
    refute inspect(rejected) =~ "audit-secret"
  end

  test "cursor-paginated lists reject duplicate canonical IDs before bounding" do
    duplicate_audit_id = "audit-duplicate"

    duplicate_audits = [
      Map.put(audit(1), "audit_id", duplicate_audit_id),
      Map.put(audit(2), "audit_id", duplicate_audit_id)
    ]

    duplicate_hosts = [
      host("host-duplicate", "pending"),
      host("host-duplicate", "approved")
    ]

    for {operation, owner_function, response} <- [
          {"server.identity.audit.list", :control_list_audit, {:ok, duplicate_audits}},
          {"server.identity.hosts.list", :control_list_hosts, {:ok, duplicate_hosts}}
        ] do
      YellowDog.ServerIdentityControlFake.configure(%{owner_function => response})

      result = Dispatcher.dispatch(envelope(operation, %{"limit" => 1}))

      assert {:error, %Error{code: :invalid, message: "invalid value", details: %{}}} = result
      assert [{^owner_function, []}] = YellowDog.ServerIdentityControlFake.take_calls()
    end
  end

  test "approve, revoke, and delete use exact owner snapshots through the real Dispatcher" do
    pending = host("host-1", "pending")
    approved = host("host-1", "approved")
    revoked = host("host-1", "revoked")

    YellowDog.ServerIdentityControlFake.configure(%{
      control_host: {:ok, pending},
      control_approve_host: {:ok, pending, approved}
    })

    assert {:ok, approved_result} =
             Dispatcher.dispatch(
               envelope(
                 "server.identity.hosts.approve",
                 %{"host_id" => "host-1"},
                 expected_revision: pending["revision"]
               )
             )

    assert approved_result == revisioned_host(approved)
    assert_valid_result("server.identity.hosts.approve", approved_result)

    YellowDog.ServerIdentityControlFake.configure(%{
      control_host: {:ok, approved},
      control_revoke_host: {:ok, approved, revoked}
    })

    assert {:ok, revoked_result} =
             Dispatcher.dispatch(
               envelope(
                 "server.identity.hosts.revoke",
                 %{"host_id" => "host-1"},
                 expected_revision: approved["revision"]
               )
             )

    assert revoked_result == revisioned_host(revoked)
    assert_valid_result("server.identity.hosts.revoke", revoked_result)

    YellowDog.ServerIdentityControlFake.configure(%{
      control_host: {:ok, revoked},
      control_delete_host: {:ok, revoked}
    })

    assert {:ok, deleted_result} =
             Dispatcher.dispatch(
               envelope(
                 "server.identity.hosts.delete",
                 %{"host_id" => "host-1"},
                 expected_revision: revoked["revision"]
               )
             )

    assert deleted_result == %{
             "resource_type" => "identity_host",
             "resource_id" => "host-1",
             "revision" => revoked["revision"],
             "resource_ref" => %{"host_id" => "host-1"}
           }

    assert_valid_result("server.identity.hosts.delete", deleted_result)
  end

  test "current returns the exact canonical host and Dispatcher alone rejects stale mutations" do
    for {operation, mutation_key} <- [
          {"server.identity.hosts.approve", :control_approve_host},
          {"server.identity.hosts.revoke", :control_revoke_host},
          {"server.identity.hosts.delete", :control_delete_host}
        ] do
      current = host("host-stale", "pending")

      YellowDog.ServerIdentityControlFake.configure(
        %{control_host: {:ok, current}}
        |> Map.put(mutation_key, {:raise, "must not mutate stale identity"})
      )

      assert {:ok, ^current} = Identity.current(operation, %{"host_id" => "host-stale"})

      YellowDog.ServerIdentityControlFake.take_calls()

      assert_error(
        :conflict,
        Dispatcher.dispatch(
          envelope(
            operation,
            %{"host_id" => "host-stale"},
            expected_revision: String.duplicate("a", 64)
          )
        )
      )

      assert [{:control_host, ["host-stale"]}] =
               YellowDog.ServerIdentityControlFake.take_calls()
    end
  end

  test "approval and token lists are strict, sorted, bounded, and secret-free" do
    approvals = [approval("approval-2", "host-2"), approval("approval-1", "host-1")]
    tokens = [token("token-2", "second", "revoked"), token("token-1", "first", "active")]

    YellowDog.ServerIdentityControlFake.configure(%{
      control_list_approvals: {:ok, approvals},
      control_list_tokens: {:ok, tokens}
    })

    assert {:ok, approval_result} =
             Dispatcher.dispatch(
               envelope("server.identity.approvals.list", %{
                 "cursor" => "approval-1",
                 "limit" => 1
               })
             )

    assert approval_result["items"] == [approval("approval-2", "host-2")]
    assert approval_result["observed_at"] == @observed_at
    assert_valid_result("server.identity.approvals.list", approval_result)

    assert {:ok, token_result} =
             Dispatcher.dispatch(
               envelope("server.identity.tokens.list", %{
                 "cursor" => "token-1",
                 "limit" => 1
               })
             )

    assert token_result["items"] == [token("token-2", "second", "revoked")]
    assert token_result["observed_at"] == @observed_at
    assert_valid_result("server.identity.tokens.list", token_result)
    refute inspect(token_result) =~ "token_hash"
    refute inspect(token_result) =~ "secret"

    malformed = Map.put(token("token-1", "first", "active"), "token_hash", "stored-secret")
    YellowDog.ServerIdentityControlFake.configure(%{control_list_tokens: {:ok, [malformed]}})

    rejected = Identity.dispatch("server.identity.tokens.list", %{})
    assert_error(:invalid, rejected)
    refute inspect(rejected) =~ "stored-secret"
  end

  test "policy reads return the exact validated set used for mutation CAS" do
    policies = [policy("z-policy", "deny"), policy("a-policy", "require_approval")]
    YellowDog.ServerIdentityControlFake.configure(%{control_list_policies: {:ok, policies}})

    assert {:ok, result} =
             Dispatcher.dispatch(envelope("server.identity.policies.get", %{}))

    assert result == %{"policies" => Enum.sort_by(policies, & &1["policy_id"])}
    assert_valid_result("server.identity.policies.get", result)

    assert {:ok, ^result} =
             Identity.current("server.identity.policies.update", %{
               "policies" => [policy("replacement", "allow")]
             })
  end

  test "token create returns its secret once while reads and current stay redacted" do
    payload = %{"token_id" => "token-1", "label" => "bootstrap", "expires_at" => nil}
    resource = token("token-1", "bootstrap", "active")

    YellowDog.ServerIdentityControlFake.configure(%{
      control_token: {:error, :not_found},
      control_create_token: {:ok, resource, "one-time-secret", nil}
    })

    assert {:ok, :missing} = Identity.current("server.identity.tokens.create", payload)
    assert [{:control_token, ["token-1"]}] = YellowDog.ServerIdentityControlFake.take_calls()

    assert {:ok, result} =
             Dispatcher.dispatch(envelope("server.identity.tokens.create", payload))

    assert result == %{
             "token_id" => "token-1",
             "secret" => "one-time-secret",
             "expires_at" => nil
           }

    assert_valid_result("server.identity.tokens.create", result)

    assert [{:control_token, ["token-1"]}, {:control_create_token, [^payload]}] =
             YellowDog.ServerIdentityControlFake.take_calls()

    YellowDog.ServerIdentityControlFake.configure(%{control_token: {:ok, resource}})
    assert {:ok, ^resource} = Identity.current("server.identity.tokens.create", payload)
    refute inspect(resource) =~ "one-time-secret"
  end

  test "token revoke uses the exact current token and returns the durable revoked resource" do
    active = token("token-1", "bootstrap", "active")
    revoked = token("token-1", "bootstrap", "revoked")

    YellowDog.ServerIdentityControlFake.configure(%{
      control_token: {:ok, active},
      control_revoke_token: {:ok, active, revoked}
    })

    assert {:ok, result} =
             Dispatcher.dispatch(
               envelope(
                 "server.identity.tokens.revoke",
                 %{"token_id" => "token-1"},
                 expected_revision: revision!(active)
               )
             )

    assert result == revisioned_resource("identity_token", "token-1", revoked)
    assert_valid_result("server.identity.tokens.revoke", result)

    YellowDog.ServerIdentityControlFake.configure(%{
      control_revoke_token: {:raise, "must not mutate a stale token"}
    })

    assert_error(
      :conflict,
      Dispatcher.dispatch(
        envelope(
          "server.identity.tokens.revoke",
          %{"token_id" => "token-1"},
          expected_revision: String.duplicate("a", 64)
        )
      )
    )

    assert [
             {:control_token, ["token-1"]},
             {:control_revoke_token, ["token-1"]},
             {:control_token, ["token-1"]}
           ] = YellowDog.ServerIdentityControlFake.take_calls()
  end

  test "a single policy update compares the full current set and returns the changed policy" do
    prior = [policy("policy-1", "require_approval")]
    resulting = [policy("policy-1", "deny")]
    payload = %{"policies" => resulting}
    current = %{"policies" => prior}

    YellowDog.ServerIdentityControlFake.configure(%{
      control_list_policies: {:ok, prior},
      control_update_policies: {:ok, prior, resulting}
    })

    assert {:ok, result} =
             Dispatcher.dispatch(
               envelope(
                 "server.identity.policies.update",
                 payload,
                 expected_revision: revision!(current)
               )
             )

    assert result ==
             revisioned_resource("identity_policy", "policy-1", hd(resulting))

    assert_valid_result("server.identity.policies.update", result)

    assert [
             {:control_list_policies, []},
             {:control_update_policies, [^resulting]}
           ] = YellowDog.ServerIdentityControlFake.take_calls()
  end

  test "multi-policy updates fail before touching the owner because the result is one resource" do
    payload = %{
      "policies" => [policy("policy-1", "allow"), policy("policy-2", "deny")]
    }

    assert_error(:invalid, Identity.current("server.identity.policies.update", payload))
    assert_error(:invalid, Identity.dispatch("server.identity.policies.update", payload))
    assert [] = YellowDog.ServerIdentityControlFake.take_calls()
  end

  test "unsupported gaps reject malformed payloads before returning unsupported" do
    cases = [
      {"server.identity.approvals.list", %{"limit" => 0}},
      {"server.identity.tokens.list", %{"cursor" => ""}},
      {"server.identity.policies.get", %{"unexpected" => true}},
      {"server.identity.tokens.create",
       %{"token_id" => "token-1", "label" => "", "expires_at" => nil}},
      {"server.identity.tokens.revoke", %{"token_id" => ""}},
      {"server.identity.policies.update",
       %{
         "policies" => [
           %{"policy_id" => "policy-1", "action" => "approve", "enabled" => true}
         ]
       }}
    ]

    for {operation, payload} <- cases do
      assert_error(:invalid, Identity.dispatch(operation, payload))

      unless String.ends_with?(operation, ".list") or
               operation == "server.identity.policies.get" do
        assert_error(:invalid, Identity.current(operation, payload))
      end
    end

    assert [] = YellowDog.ServerIdentityControlFake.take_calls()
  end

  test "disabled and unavailable Identity service gates invoke no owner" do
    YellowDog.ServerControlFake.set_available(:identity, false)

    assert_error(
      :unsupported,
      Dispatcher.dispatch(envelope("server.identity.hosts.list", %{}))
    )

    assert [] = YellowDog.ServerIdentityControlFake.take_calls()

    YellowDog.ServerControlFake.set_available(:identity, true)
    YellowDog.ServerControlFake.set_enabled(:identity, false)

    assert_error(
      :unsupported,
      Dispatcher.dispatch(
        envelope(
          "server.identity.hosts.approve",
          %{"host_id" => "host-1"},
          expected_revision: String.duplicate("a", 64)
        )
      )
    )

    assert [] = YellowDog.ServerIdentityControlFake.take_calls()
  end

  test "owner errors, malformed returns, exceptions, and exits are sanitized" do
    raw_path = "/var/lib/yellowdog/identity/hosts/secret.toml"

    mappings = [
      {:not_found, {:error, :not_found}},
      {:not_found, {:error, :noproc}},
      {:conflict, {:error, :conflict}},
      {:conflict, {:error, :already_revoked}},
      {:conflict, {:error, {:invalid_status, :approved}}},
      {:invalid, {:error, :invalid}},
      {:apply_failed, {:error, :persistence_failed}},
      {:apply_failed, :malformed},
      {:apply_failed, {:raise, "owner secret #{raw_path}"}},
      {:apply_failed, {:throw, {:raw_path, raw_path}}},
      {:apply_failed, {:exit, {:owner_failed, raw_path}}}
    ]

    for {code, response} <- mappings do
      YellowDog.ServerIdentityControlFake.configure(%{control_list_hosts: response})
      result = Dispatcher.dispatch(envelope("server.identity.hosts.list", %{}))
      assert_error(code, result)
      refute inspect(result) =~ raw_path
    end

    noproc =
      {:noproc,
       {GenServer, :call, [YellowDog.ServerIdentityControlFake.Owner, :control_list_hosts, 5_000]}}

    YellowDog.ServerIdentityControlFake.configure(%{
      control_list_hosts: {:exit, noproc}
    })

    assert_error(
      :not_found,
      Dispatcher.dispatch(envelope("server.identity.hosts.list", %{}))
    )
  end

  test "invalid owner snapshots and mutation transitions fail without disclosing material" do
    secret_host =
      host("host-1", "pending")
      |> Map.put("ssh_public_key", "ssh-ed25519 secret")
      |> Map.put("token_hash", "token-secret")

    YellowDog.ServerIdentityControlFake.configure(%{
      control_list_hosts: {:ok, [secret_host]}
    })

    result = Dispatcher.dispatch(envelope("server.identity.hosts.list", %{}))
    assert_error(:invalid, result)
    refute inspect(result) =~ "token-secret"
    refute inspect(result) =~ "ssh-ed25519"

    YellowDog.ServerIdentityControlFake.configure(%{
      control_list_hosts: {:ok, [%URI{path: "/private/identity/host.toml"}]}
    })

    struct_result = Dispatcher.dispatch(envelope("server.identity.hosts.list", %{}))
    assert_error(:invalid, struct_result)
    refute inspect(struct_result) =~ "/private/identity"

    pending = host("host-1", "pending")
    wrong_host = host("host-2", "approved")

    YellowDog.ServerIdentityControlFake.configure(%{
      control_approve_host: {:ok, pending, wrong_host}
    })

    mutation =
      Identity.dispatch("server.identity.hosts.approve", %{"host_id" => "host-1"})

    assert_error(:invalid, mutation)
    refute inspect(mutation) =~ "host-2"
  end

  test "missing owner entry points and invalid test overrides fail closed" do
    config =
      Application.fetch_env!(:yellow_dog, Identity)
      |> Keyword.put(:identity, YellowDog.ServerIdentityControlFake.Clock)

    Application.put_env(:yellow_dog, Identity, config)
    assert_error(:not_found, Identity.dispatch("server.identity.hosts.list", %{}))

    Application.put_env(:yellow_dog, Identity,
      identity: YellowDog.ServerIdentityControlFake.InternalUndefinedFunctionOwner,
      clock: YellowDog.ServerIdentityControlFake.Clock
    )

    assert_error(:apply_failed, Identity.dispatch("server.identity.hosts.list", %{}))

    Application.put_env(:yellow_dog, Identity,
      identity: System,
      unexpected_owner: System
    )

    assert_error(:apply_failed, Identity.dispatch("server.identity.hosts.list", %{}))
  end

  test "malformed token owner returns fail closed without disclosing secret material" do
    YellowDog.ServerIdentityControlFake.configure(%{
      control_list_tokens: {:ok, [%{"raw_token" => "one-time-secret"}]},
      control_token: {:ok, %{"raw_token" => "one-time-secret"}},
      control_create_token: {:ok, %{"secret" => "one-time-secret"}},
      control_revoke_token: {:ok, %{"token_hash" => "stored-secret"}}
    })

    operations = [
      {"server.identity.tokens.list", %{}},
      {"server.identity.tokens.create",
       %{"token_id" => "token-1", "label" => "bootstrap", "expires_at" => nil}},
      {"server.identity.tokens.revoke", %{"token_id" => "token-1"}}
    ]

    for {operation, payload} <- operations do
      result = Identity.dispatch(operation, payload)
      assert_error(:invalid, result)
      refute inspect(result) =~ "one-time-secret"
      refute inspect(result) =~ "stored-secret"
    end
  end

  defp host(id, state) do
    resource = %{
      "host_id" => id,
      "name" => "Host #{id}",
      "state" => state
    }

    {:ok, revision} = Revision.calculate(resource)
    Map.put(resource, "revision", revision)
  end

  defp audit(index) do
    suffix = String.pad_leading(Integer.to_string(index), 4, "0")

    %{
      "audit_id" => "audit-#{suffix}",
      "action" => "host.registered",
      "subject_id" => "host-#{suffix}",
      "occurred_at" => "2026-07-17T00:00:00Z"
    }
  end

  defp approval(approval_id, host_id) do
    %{"approval_id" => approval_id, "host_id" => host_id, "state" => "pending"}
  end

  defp token(token_id, label, state) do
    %{"token_id" => token_id, "label" => label, "state" => state}
  end

  defp policy(policy_id, action) do
    %{"policy_id" => policy_id, "action" => action, "enabled" => true}
  end

  defp revisioned_host(host) do
    %{
      "resource_type" => "identity_host",
      "resource_id" => host["host_id"],
      "revision" => host["revision"],
      "resource" => host
    }
  end

  defp revisioned_resource(resource_type, resource_id, resource) do
    %{
      "resource_type" => resource_type,
      "resource_id" => resource_id,
      "revision" => revision!(resource),
      "resource" => resource
    }
  end

  defp revision!(resource) do
    {:ok, revision} = Revision.calculate(resource)
    revision
  end

  defp envelope(operation, payload, overrides \\ []) do
    {:ok, payload_digest} = Digest.calculate(payload)

    %Envelope{
      protocol_version: 1,
      request_id: @request_id,
      target_type: :server,
      target_id: "server-task-7c",
      operation: operation,
      idempotency_key: @idempotency_key,
      payload: payload,
      payload_digest: payload_digest,
      expected_revision: Keyword.get(overrides, :expected_revision),
      config_version: nil,
      sent_at: @sent_at
    }
  end

  defp assert_valid_result(operation_name, result) do
    assert {:ok, operation} = ServerOperation.fetch(operation_name)
    assert {:ok, ^result} = Operation.validate_result(operation, result)
  end

  defp assert_error(code, {:error, %Error{code: code, details: %{}}}), do: :ok
  defp assert_error(code, other), do: flunk("expected #{code}, got: #{inspect(other)}")

  defp restore_env(module, nil), do: Application.delete_env(:yellow_dog, module)
  defp restore_env(module, config), do: Application.put_env(:yellow_dog, module, config)
end
