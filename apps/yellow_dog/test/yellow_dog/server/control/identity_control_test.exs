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

  test "all unsupported reads and mutations validate then stay owner-free through Dispatcher" do
    cases = [
      {"server.identity.approvals.list", %{}, :query},
      {"server.identity.tokens.list", %{}, :query},
      {"server.identity.policies.get", %{}, :query},
      {"server.identity.tokens.create",
       %{"token_id" => "token-1", "label" => "bootstrap", "expires_at" => nil}, :mutation},
      {"server.identity.tokens.revoke", %{"token_id" => "token-1"}, :mutation},
      {"server.identity.policies.update",
       %{
         "policies" => [
           %{"policy_id" => "policy-1", "action" => "deny", "enabled" => true}
         ]
       }, :mutation}
    ]

    for {operation, payload, kind} <- cases do
      assert_error(:unsupported, Dispatcher.dispatch(envelope(operation, payload)))
      assert_error(:unsupported, Identity.dispatch(operation, payload))

      if kind == :mutation do
        assert_error(:unsupported, Identity.current(operation, payload))
      end
    end

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

  test "token operations cannot call owners or disclose one-time token material" do
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
      result = Dispatcher.dispatch(envelope(operation, payload))
      assert_error(:unsupported, result)
      refute inspect(result) =~ "one-time-secret"
      refute inspect(result) =~ "stored-secret"
    end

    assert [] = YellowDog.ServerIdentityControlFake.take_calls()
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

  defp revisioned_host(host) do
    %{
      "resource_type" => "identity_host",
      "resource_id" => host["host_id"],
      "revision" => host["revision"],
      "resource" => host
    }
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
