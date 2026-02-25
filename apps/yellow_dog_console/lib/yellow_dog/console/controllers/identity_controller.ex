defmodule YellowDog.Console.IdentityController do
  use YellowDog.Console, :controller

  # No action_fallback — errors handled inline per action

  @doc """
  POST /api/hosts/register

  Registers a new host identity.
  """
  def register(conn, params) do
    context = %{
      source_ip: conn.remote_ip,
      authorization: get_req_header(conn, "authorization") |> List.first(),
      attestation: Map.get(params, "attestation")
    }

    case YellowDogIdentity.register(params, context) do
      {:ok, host} ->
        conn
        |> put_status(if(host.status == :approved, do: 200, else: 201))
        |> json(%{
          id: host.id,
          status: to_string(host.status),
          trust_level: to_string(host.trust_level),
          trust_provider: to_string(host.trust_provider),
          message: "Registration accepted"
        })

      {:error, {:idempotent, existing}} ->
        conn
        |> put_status(200)
        |> json(%{
          id: existing.id,
          status: to_string(existing.status),
          trust_level: to_string(existing.trust_level),
          trust_provider: to_string(existing.trust_provider),
          message: "Already registered"
        })

      {:error, :conflict} ->
        conn
        |> put_status(409)
        |> json(%{
          error: "conflict",
          message: "Hostname registered with different key. Use force: true to replace."
        })

      {:error, reason} ->
        conn
        |> put_status(422)
        |> json(%{error: sanitize_error(reason)})
    end
  end

  @doc """
  GET /api/hosts/recipients

  Exports approved host recipients.
  Query param: format=sops for .sops.yaml format.
  """
  def recipients(conn, params) do
    format = Map.get(params, "format", "yaml")

    content =
      case format do
        "sops" -> YellowDogIdentity.export_recipients(format: :sops)
        _ -> YellowDogIdentity.export_recipients(format: :yaml)
      end

    conn
    |> put_resp_content_type("text/yaml")
    |> send_resp(200, content)
  end

  @doc """
  GET /api/hosts/:id/status

  Returns the current status of a host (for revocation checking).
  """
  def status(conn, %{"id" => id}) do
    case YellowDogIdentity.host_status(id) do
      {:ok, status_map} ->
        response =
          %{
            id: status_map.id,
            hostname: status_map.hostname,
            status: to_string(status_map.status),
            trust_level: to_string(status_map.trust_level),
            trust_provider: to_string(status_map.trust_provider),
            key_fingerprint: status_map.key_fingerprint
          }
          |> maybe_put(:approved_at, status_map.approved_at)
          |> maybe_put(:revoked_at, status_map.revoked_at)
          |> maybe_put(:revoke_reason, status_map.revoke_reason)

        json(conn, response)

      :not_found ->
        conn
        |> put_status(404)
        |> json(%{error: "not_found"})
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, %DateTime{} = dt), do: Map.put(map, key, DateTime.to_iso8601(dt))
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc """
  PUT /api/hosts/:id/approve

  Approves a pending host.
  """
  def approve(conn, %{"id" => id}) do
    approved_by = Map.get(conn.body_params, "approved_by", "api")

    case YellowDogIdentity.approve(id, approved_by) do
      {:ok, host} ->
        json(conn, %{
          id: host.id,
          hostname: host.hostname,
          status: to_string(host.status),
          approved_by: host.approved_by,
          message: "Host approved"
        })

      {:error, {:invalid_status, status}} ->
        conn
        |> put_status(409)
        |> json(%{error: "invalid_status", message: "Host is #{status}, not pending"})

      {:error, :not_found} ->
        conn
        |> put_status(404)
        |> json(%{error: "not_found"})
    end
  end

  @doc """
  POST /api/hosts/:id/revoke

  Revokes a host.
  """
  def revoke(conn, %{"id" => id}) do
    revoked_by = Map.get(conn.body_params, "revoked_by", "api")
    reason = Map.get(conn.body_params, "reason", "revoked via API")

    case YellowDogIdentity.revoke(id, revoked_by, reason) do
      {:ok, host} ->
        json(conn, %{
          id: host.id,
          hostname: host.hostname,
          status: to_string(host.status),
          revoked_by: host.revoked_by,
          message: "Host revoked"
        })

      {:error, :already_revoked} ->
        conn
        |> put_status(409)
        |> json(%{error: "already_revoked", message: "Host is already revoked"})

      {:error, :not_found} ->
        conn
        |> put_status(404)
        |> json(%{error: "not_found"})
    end
  end

  @doc """
  DELETE /api/hosts/:id

  Permanently deletes a host record.
  """
  def delete(conn, %{"id" => id}) do
    case YellowDogIdentity.delete_host(id) do
      :ok ->
        json(conn, %{message: "Host deleted"})

      {:error, :not_found} ->
        conn
        |> put_status(404)
        |> json(%{error: "not_found"})
    end
  end

  # Map known error atoms to safe user-facing messages; fall back to generic message
  @known_errors %{
    hostname_required: "hostname is required",
    hostname_too_long: "hostname exceeds maximum length",
    hostname_invalid_chars: "hostname contains invalid characters",
    ssh_pubkey_required: "ssh_pubkey is required",
    age_recipient_required: "age_recipient is required",
    invalid_pubkey: "invalid SSH public key format",
    invalid_age_recipient: "invalid age recipient format",
    instance_id_conflict: "instance ID already registered",
    conflict: "hostname registered with different key"
  }

  defp sanitize_error(reason) when is_atom(reason) do
    Map.get(@known_errors, reason, "registration_failed")
  end

  defp sanitize_error(_), do: "registration_failed"
end
