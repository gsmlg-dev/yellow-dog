defmodule YellowDogIdentity do
  @moduledoc """
  Public API for the Host Identity Registry.

  Provides registration, approval, revocation, and export of machine identities
  for NixOS hosts within the Yellowdog infrastructure.
  """

  require Logger

  alias YellowDog.Server.Control.Revision
  alias YellowDogIdentity.{Host, Registry, Token, Export, Webhook}
  alias YellowDogIdentity.Trust.Router, as: TrustRouter
  alias YellowDogIdentity.Approval.Engine, as: ApprovalEngine

  @control_actor "yellow_dog_server_control"
  @control_revoke_reason "server control revocation"
  @max_control_items 100
  @supported_audit_actions ~w(host.registered host.approved host.revoked host.deleted)

  # Delegation to Supervisor for child_spec
  defdelegate start_link(opts), to: YellowDogIdentity.Supervisor
  defdelegate child_spec(opts), to: YellowDogIdentity.Supervisor

  @doc """
  Registers a new host identity.

  Validates the key, checks for duplicates/conflicts, routes through trust
  providers, and applies the approval policy.

  ## Parameters

  - `params` — Registration payload (hostname, ssh_pubkey, age_recipient, etc.)
  - `context` — Request context (source_ip, authorization header, attestation)

  ## Returns

  - `{:ok, host}` on success (host may be `:approved` or `:pending`)
  - `{:error, reason}` on failure
  """
  @spec register(map(), map()) :: {:ok, Host.t()} | {:error, term()}
  def register(params, context \\ %{}) do
    start_time = System.monotonic_time()
    hostname = Map.get(params, :hostname) || Map.get(params, "hostname", "unknown")

    YellowDogIdentity.Telemetry.registration_start(
      hostname,
      Map.get(context, :source_ip, {0, 0, 0, 0})
    )

    result = do_register(params, context)

    duration = System.monotonic_time() - start_time

    case result do
      {:ok, host} ->
        YellowDogIdentity.Telemetry.registration_stop(duration, %{
          hostname: host.hostname,
          status: host.status,
          trust_level: host.trust_level,
          trust_provider: host.trust_provider,
          policy_applied: host.approved_by
        })

        result

      {:error, reason} ->
        YellowDogIdentity.Telemetry.registration_exception(duration, hostname, reason)
        result
    end
  end

  @doc """
  Approves a pending host.
  """
  @spec approve(String.t(), String.t()) :: {:ok, Host.t()} | {:error, term()}
  def approve(host_id, approved_by \\ "manual") do
    case Registry.get_host(host_id) do
      {:ok, %Host{status: :pending} = host} ->
        now = DateTime.utc_now()

        updated = %{
          host
          | status: :approved,
            approved_at: now,
            approved_by: approved_by
        }

        case Registry.put_host(updated) do
          :ok ->
            Registry.append_audit("host.approved", host_id, %{approved_by: approved_by})
            YellowDogIdentity.Telemetry.host_approved(host_id, approved_by, host.trust_level)
            Webhook.notify("host.approved", updated)
            broadcast("identity:hosts", {:host_updated, updated})
            {:ok, updated}

          error ->
            error
        end

      {:ok, %Host{status: status}} ->
        {:error, {:invalid_status, status}}

      :not_found ->
        {:error, :not_found}
    end
  end

  @doc """
  Revokes an approved host.
  """
  @spec revoke(String.t(), String.t(), String.t()) :: {:ok, Host.t()} | {:error, term()}
  def revoke(host_id, revoked_by, reason \\ "manual revocation") do
    case Registry.get_host(host_id) do
      {:ok, %Host{status: status} = host} when status in [:approved, :pending] ->
        now = DateTime.utc_now()

        updated = %{
          host
          | status: :revoked,
            revoked_at: now,
            revoked_by: revoked_by,
            revoke_reason: reason
        }

        case Registry.put_host(updated) do
          :ok ->
            Registry.append_audit("host.revoked", host_id, %{
              revoked_by: revoked_by,
              reason: reason
            })

            YellowDogIdentity.Telemetry.host_revoked(host_id, revoked_by, reason)
            Webhook.notify("host.revoked", updated)
            broadcast("identity:hosts", {:host_updated, updated})
            {:ok, updated}

          error ->
            error
        end

      {:ok, %Host{status: :revoked}} ->
        {:error, :already_revoked}

      :not_found ->
        {:error, :not_found}
    end
  end

  @doc """
  Deletes a host record permanently.
  """
  @spec delete_host(String.t()) :: :ok | {:error, term()}
  def delete_host(id) do
    case Registry.get_host(id) do
      {:ok, host} ->
        case Registry.delete_host(id) do
          :ok ->
            Registry.append_audit("host.deleted", id, %{hostname: host.hostname})
            YellowDogIdentity.Telemetry.host_deleted(id, host.hostname)
            broadcast("identity:hosts", {:host_updated, host})
            :ok

          error ->
            error
        end

      :not_found ->
        {:error, :not_found}
    end
  end

  @doc """
  Gets a host by ID.
  """
  @spec get_host(String.t()) :: {:ok, Host.t()} | :not_found
  def get_host(id), do: Registry.get_host(id)

  @doc """
  Lists all hosts, optionally filtered by status.
  """
  @spec list_hosts(keyword()) :: [Host.t()]
  def list_hosts(opts \\ []) do
    case Keyword.get(opts, :status) do
      nil -> Registry.list_hosts()
      status -> Registry.list_hosts_by_status(status)
    end
  end

  @doc """
  Gets the status of a specific host (for revocation checking).
  """
  @spec host_status(String.t()) :: {:ok, map()} | :not_found
  def host_status(id) do
    case Registry.get_host(id) do
      {:ok, host} ->
        {:ok,
         %{
           id: host.id,
           hostname: host.hostname,
           status: host.status,
           trust_level: host.trust_level,
           trust_provider: host.trust_provider,
           approved_at: host.approved_at,
           revoked_at: host.revoked_at,
           revoke_reason: host.revoke_reason,
           key_fingerprint: host.key_fingerprint
         }}

      :not_found ->
        :not_found
    end
  end

  @doc """
  Creates a new provisioning token.
  """
  @spec create_token(map()) :: {:ok, Token.t(), String.t()} | {:error, term()}
  def create_token(params) do
    case Token.create(params) do
      {:ok, token, raw_token} ->
        case Registry.put_token(token) do
          :ok -> {:ok, token, raw_token}
          error -> error
        end

      error ->
        error
    end
  end

  @doc """
  Lists provisioning tokens.
  """
  @spec list_tokens() :: [Token.t()]
  def list_tokens, do: Registry.list_tokens()

  @doc """
  Revokes a provisioning token.
  """
  @spec revoke_token(String.t()) :: :ok | {:error, term()}
  def revoke_token(id), do: Registry.delete_token(id)

  @doc """
  Lists canonical public host snapshots for the Server control boundary.
  """
  @spec control_list_hosts() ::
          {:ok, [map()]} | {:error, :persistence_failed | :apply_failed}
  def control_list_hosts do
    control_boundary(fn ->
      case Registry.control_list_hosts() do
        {:ok, hosts} when is_list(hosts) ->
          with {:ok, snapshots} <- project_hosts(hosts) do
            {:ok, sort_and_bound(snapshots, "host_id")}
          end

        {:error, reason} ->
          control_owner_error(reason)

        _unexpected ->
          {:error, :apply_failed}
      end
    end)
  end

  @doc """
  Approval control is unsupported because Identity has no durable approval ID.
  """
  @spec control_list_approvals() :: {:error, :unsupported}
  def control_list_approvals, do: {:error, :unsupported}

  @doc """
  Token control is unsupported because persisted tokens have no durable label.
  """
  @spec control_list_tokens() :: {:error, :unsupported}
  def control_list_tokens, do: {:error, :unsupported}

  @doc """
  Returns one canonical public host snapshot.
  """
  @spec control_host(String.t()) ::
          {:ok, map()} | {:error, :not_found | :persistence_failed | :apply_failed}
  def control_host(id) do
    control_boundary(fn ->
      case Registry.control_get_host(id) do
        {:ok, %Host{} = host} -> public_host(host)
        {:error, reason} -> control_owner_error(reason)
        _unexpected -> {:error, :apply_failed}
      end
    end)
  end

  @doc """
  Token control is unsupported because persisted tokens have no durable label.
  """
  @spec control_token(String.t()) :: {:error, :unsupported}
  def control_token(_id), do: {:error, :unsupported}

  @doc """
  Atomically approves a host using the fixed Server control actor.
  """
  @spec control_approve_host(String.t()) :: {:ok, map(), map()} | {:error, term()}
  def control_approve_host(host_id) do
    control_boundary(fn ->
      case Registry.control_approve_host(host_id, @control_actor) do
        {:ok, %Host{} = prior, %Host{} = resulting} ->
          with {:ok, prior_snapshot} <- public_host(prior),
               {:ok, resulting_snapshot} <- public_host(resulting) do
            control_side_effects(fn ->
              Registry.append_audit("host.approved", host_id, %{approved_by: @control_actor})

              YellowDogIdentity.Telemetry.host_approved(
                host_id,
                @control_actor,
                prior.trust_level
              )

              Webhook.notify("host.approved", resulting)
              broadcast("identity:hosts", {:host_updated, resulting})
            end)

            {:ok, prior_snapshot, resulting_snapshot}
          end

        {:error, reason} ->
          control_owner_error(reason)

        _unexpected ->
          {:error, :apply_failed}
      end
    end)
  end

  @doc """
  Atomically revokes a host using the fixed Server control actor.
  """
  @spec control_revoke_host(String.t()) :: {:ok, map(), map()} | {:error, term()}
  def control_revoke_host(host_id) do
    control_boundary(fn ->
      case Registry.control_revoke_host(
             host_id,
             @control_actor,
             @control_revoke_reason
           ) do
        {:ok, %Host{} = prior, %Host{} = resulting} ->
          with {:ok, prior_snapshot} <- public_host(prior),
               {:ok, resulting_snapshot} <- public_host(resulting) do
            control_side_effects(fn ->
              Registry.append_audit("host.revoked", host_id, %{
                revoked_by: @control_actor,
                reason: @control_revoke_reason
              })

              YellowDogIdentity.Telemetry.host_revoked(
                host_id,
                @control_actor,
                @control_revoke_reason
              )

              Webhook.notify("host.revoked", resulting)
              broadcast("identity:hosts", {:host_updated, resulting})
            end)

            {:ok, prior_snapshot, resulting_snapshot}
          end

        {:error, reason} ->
          control_owner_error(reason)

        _unexpected ->
          {:error, :apply_failed}
      end
    end)
  end

  @doc """
  Atomically snapshots and durably deletes a host.
  """
  @spec control_delete_host(String.t()) :: {:ok, map()} | {:error, term()}
  def control_delete_host(host_id) do
    control_boundary(fn ->
      case Registry.control_delete_host(host_id) do
        {:ok, %Host{} = prior} ->
          with {:ok, prior_snapshot} <- public_host(prior) do
            control_side_effects(fn ->
              Registry.append_audit("host.deleted", host_id, %{hostname: prior.hostname})
              YellowDogIdentity.Telemetry.host_deleted(host_id, prior.hostname)
              broadcast("identity:hosts", {:host_updated, prior})
            end)

            {:ok, prior_snapshot}
          end

        {:error, reason} ->
          control_owner_error(reason)

        _unexpected ->
          {:error, :apply_failed}
      end
    end)
  end

  @doc """
  Token control is unsupported because persisted tokens have no durable label.
  """
  @spec control_revoke_token(String.t()) :: {:error, :unsupported}
  def control_revoke_token(_token_id), do: {:error, :unsupported}

  @doc """
  Exports approved recipients in YAML format.
  """
  @spec export_recipients(keyword()) :: String.t()
  def export_recipients(opts \\ []) do
    case Keyword.get(opts, :format, :yaml) do
      :sops -> Export.recipients_sops()
      _ -> Export.recipients_yaml()
    end
  end

  @doc """
  Reads the audit log. Options: limit (default 100), host_id, event.
  """
  @spec audit_log(keyword()) :: [map()]
  def audit_log(opts \\ []) do
    Registry.read_audit_log(opts)
  rescue
    e ->
      Logger.debug("audit_log unavailable: #{Exception.message(e)}")
      []
  end

  @doc """
  Reads deterministic, bounded audit snapshots without raw details.
  """
  @spec control_list_audit() ::
          {:ok, [map()]} | {:error, :persistence_failed | :apply_failed}
  def control_list_audit do
    control_boundary(fn ->
      case Registry.control_read_audit_log(limit: 1_000) do
        {:ok, entries} when is_list(entries) ->
          snapshots =
            entries
            |> Enum.flat_map(fn entry ->
              case public_audit(entry) do
                {:ok, snapshot} -> [snapshot]
                :error -> []
              end
            end)
            |> Enum.take(@max_control_items)

          {:ok, snapshots}

        {:error, reason} ->
          control_owner_error(reason)

        _unexpected ->
          {:error, :apply_failed}
      end
    end)
  end

  @doc """
  Returns the configured approval policies and default action.
  """
  @spec list_policies() :: map()
  def list_policies do
    ApprovalEngine.list_policies()
  rescue
    e ->
      Logger.debug("list_policies unavailable: #{Exception.message(e)}")
      %{policies: [], default_action: :pending}
  end

  @doc """
  Returns summary statistics.
  """
  @spec stats() :: map()
  def stats do
    hosts = Registry.list_hosts()
    tokens = Registry.list_tokens()

    %{
      total: length(hosts),
      pending: Enum.count(hosts, &(&1.status == :pending)),
      approved: Enum.count(hosts, &(&1.status == :approved)),
      revoked: Enum.count(hosts, &(&1.status == :revoked)),
      trust_levels:
        hosts
        |> Enum.frequencies_by(& &1.trust_level)
        |> Map.new(fn {k, v} -> {to_string(k), v} end),
      providers:
        hosts
        |> Enum.frequencies_by(& &1.trust_provider)
        |> Map.new(fn {k, v} -> {to_string(k), v} end),
      active_tokens: Enum.count(tokens, &Token.valid?/1),
      total_tokens: length(tokens)
    }
  rescue
    e ->
      Logger.warning("stats unavailable: #{Exception.message(e)}")

      %{
        total: 0,
        pending: 0,
        approved: 0,
        revoked: 0,
        trust_levels: %{},
        providers: %{},
        active_tokens: 0,
        total_tokens: 0
      }
  end

  defp public_host(%Host{} = host) do
    base = %{
      "host_id" => host.id,
      "name" => host.hostname,
      "state" => Atom.to_string(host.status)
    }

    case Revision.calculate(base) do
      {:ok, revision} -> {:ok, Map.put(base, "revision", revision)}
      {:error, _reason} -> {:error, :apply_failed}
    end
  end

  defp public_audit(%{event: action, host_id: subject_id, timestamp: timestamp})
       when action in @supported_audit_actions do
    with true <- valid_control_id?(subject_id),
         {:ok, datetime, 0} <- DateTime.from_iso8601(timestamp),
         occurred_at = DateTime.to_iso8601(datetime),
         {:ok, revision} <-
           Revision.calculate(%{
             "action" => action,
             "subject_id" => subject_id,
             "occurred_at" => occurred_at
           }) do
      {:ok,
       %{
         "audit_id" => "audit-" <> revision,
         "action" => action,
         "subject_id" => subject_id,
         "occurred_at" => occurred_at
       }}
    else
      _ -> :error
    end
  end

  defp public_audit(_entry), do: :error

  defp project_hosts(hosts) do
    Enum.reduce_while(hosts, {:ok, []}, fn
      %Host{} = host, {:ok, snapshots} ->
        case public_host(host) do
          {:ok, snapshot} -> {:cont, {:ok, [snapshot | snapshots]}}
          {:error, :apply_failed} = error -> {:halt, error}
        end

      _unexpected, _acc ->
        {:halt, {:error, :apply_failed}}
    end)
    |> case do
      {:ok, snapshots} -> {:ok, Enum.reverse(snapshots)}
      {:error, :apply_failed} = error -> error
    end
  end

  defp sort_and_bound(items, key) do
    items
    |> Enum.sort_by(&Map.fetch!(&1, key))
    |> Enum.take(@max_control_items)
  end

  defp valid_control_id?(value) when is_binary(value) do
    value != "" and byte_size(value) <= 128 and String.valid?(value)
  end

  defp valid_control_id?(_value), do: false

  defp control_owner_error(:not_found), do: {:error, :not_found}
  defp control_owner_error(:already_revoked), do: {:error, :already_revoked}
  defp control_owner_error(:persistence_failed), do: {:error, :persistence_failed}

  defp control_owner_error({:invalid_status, status})
       when status in [:pending, :approved, :revoked],
       do: {:error, {:invalid_status, status}}

  defp control_owner_error(_reason), do: {:error, :apply_failed}

  defp control_boundary(fun) do
    fun.()
  rescue
    _exception ->
      Logger.warning("Identity control owner operation failed")
      {:error, :apply_failed}
  catch
    _kind, _reason ->
      Logger.warning("Identity control owner operation failed")
      {:error, :apply_failed}
  end

  defp control_side_effects(fun) do
    fun.()
    :ok
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  # Private implementation

  defp do_register(params, context) do
    with {:ok, host} <- Host.new(params),
         :ok <- check_duplicate(host),
         {:ok, host} <- check_conflict(host, params),
         {trust_level, trust_provider, evidence} <- verify_trust(host, context),
         :ok <- check_instance_id_uniqueness(evidence),
         host <- apply_trust(host, trust_level, trust_provider, evidence),
         host <- apply_approval(host),
         :ok <- Registry.put_host(host) do
      Registry.append_audit("host.registered", host.id, %{
        hostname: host.hostname,
        status: host.status,
        trust_level: host.trust_level
      })

      # Fire key_rotated webhook if this was a forced re-registration with a new key
      if host.previous_keys != [] do
        Webhook.notify("host.key_rotated", host)
      end

      case host.status do
        :approved -> Webhook.notify("host.approved", host)
        _ -> Webhook.notify("host.registered", host)
      end

      broadcast("identity:hosts", {:host_registered, host})
      {:ok, host}
    end
  end

  defp check_duplicate(host) do
    case Registry.get_host_by_fingerprint(host.key_fingerprint) do
      {:ok, existing} ->
        if existing.hostname == host.hostname do
          # Idempotent — same key, same hostname
          {:error, {:idempotent, existing}}
        else
          # Same key, different hostname — allowed (key is identity, hostname is label)
          :ok
        end

      :not_found ->
        :ok
    end
  rescue
    e ->
      Logger.debug("check_duplicate skipped: #{Exception.message(e)}")
      :ok
  end

  defp check_conflict(host, params) do
    force = Map.get(params, :force) || Map.get(params, "force", false)

    case Registry.get_host_by_hostname(host.hostname) do
      {:ok, existing} ->
        if existing.key_fingerprint == host.key_fingerprint do
          # Same key — idempotent
          {:error, {:idempotent, existing}}
        else
          if force do
            # Archive old key and proceed
            previous_key = %{
              "ssh_pubkey" => existing.ssh_pubkey,
              "key_fingerprint" => existing.key_fingerprint,
              "replaced_at" => DateTime.to_iso8601(DateTime.utc_now())
            }

            updated_host = %{
              host
              | previous_keys: existing.previous_keys ++ [previous_key],
                id: existing.id
            }

            # Delete old host record (will be replaced)
            Registry.delete_host(existing.id)
            {:ok, updated_host}
          else
            {:error, :conflict}
          end
        end

      :not_found ->
        {:ok, host}
    end
  rescue
    e ->
      Logger.debug("check_conflict skipped: #{Exception.message(e)}")
      {:ok, host}
  end

  defp check_instance_id_uniqueness(evidence) when is_map(evidence) do
    instance_id =
      Map.get(evidence, :instance_id) || Map.get(evidence, "instance_id")

    if instance_id do
      # Check all hosts for duplicate cloud instance ID
      hosts = Registry.list_hosts()

      case Enum.find(hosts, fn h ->
             eid = h.trust_evidence
             (Map.get(eid, :instance_id) || Map.get(eid, "instance_id")) == to_string(instance_id)
           end) do
        nil -> :ok
        _existing -> {:error, :instance_id_conflict}
      end
    else
      :ok
    end
  rescue
    e ->
      Logger.warning("check_instance_id_uniqueness failed: #{Exception.message(e)}")
      :ok
  end

  defp check_instance_id_uniqueness(_), do: :ok

  defp verify_trust(host, context) do
    trust_context = %{
      source_ip: Map.get(context, :source_ip, {0, 0, 0, 0}),
      hostname: host.hostname,
      attestation: Map.get(context, :attestation) || Map.get(context, "attestation"),
      metadata: host.metadata,
      authorization: Map.get(context, :authorization)
    }

    TrustRouter.verify(trust_context)
  end

  defp apply_trust(host, trust_level, trust_provider, evidence) do
    %{host | trust_level: trust_level, trust_provider: trust_provider, trust_evidence: evidence}
  end

  defp broadcast(topic, message) do
    Phoenix.PubSub.broadcast(YellowDog.Console.PubSub, topic, message)
  rescue
    _ -> :ok
  end

  defp apply_approval(host) do
    case ApprovalEngine.evaluate(host) do
      %{action: :approve, policy_name: name} ->
        %{
          host
          | status: :approved,
            approved_at: DateTime.utc_now(),
            approved_by: "auto:#{name}"
        }

      %{action: :reject, policy_name: name} ->
        %{host | status: :pending, revoke_reason: "rejected by policy: #{name}"}

      %{action: :reject} ->
        %{host | status: :pending, revoke_reason: "rejected by policy"}

      _ ->
        host
    end
  end
end
