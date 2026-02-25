defmodule YellowDogIdentity do
  @moduledoc """
  Public API for the Host Identity Registry.

  Provides registration, approval, revocation, and export of machine identities
  for NixOS hosts within the Yellowdog infrastructure.
  """

  alias YellowDogIdentity.{Host, Registry, Token, Export, Webhook}
  alias YellowDogIdentity.Trust.Router, as: TrustRouter
  alias YellowDogIdentity.Approval.Engine, as: ApprovalEngine

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
           trust_level: host.trust_level
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
    _ -> []
  end

  @doc """
  Returns the configured approval policies and default action.
  """
  @spec list_policies() :: map()
  def list_policies do
    ApprovalEngine.list_policies()
  rescue
    _ -> %{policies: [], default_action: :pending}
  end

  @doc """
  Returns summary statistics.
  """
  @spec stats() :: map()
  def stats do
    hosts = Registry.list_hosts()

    %{
      total: length(hosts),
      pending: Enum.count(hosts, &(&1.status == :pending)),
      approved: Enum.count(hosts, &(&1.status == :approved)),
      revoked: Enum.count(hosts, &(&1.status == :revoked)),
      trust_levels:
        hosts
        |> Enum.frequencies_by(& &1.trust_level)
        |> Map.new(fn {k, v} -> {to_string(k), v} end)
    }
  rescue
    _ ->
      %{total: 0, pending: 0, approved: 0, revoked: 0, trust_levels: %{}}
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
    # Registry may not be started yet
    _ -> :ok
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
    _ -> {:ok, host}
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
    _ -> :ok
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
