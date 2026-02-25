defmodule YellowDogIdentity.Host do
  import Bitwise

  @moduledoc """
  Host identity struct representing a registered machine.

  The host record stores public identity material (never private keys),
  trust verification evidence, and approval state.
  """

  @type status :: :pending | :approved | :revoked

  @type trust_level ::
          :cloud_verified
          | :netboot_verified
          | :network_verified
          | :network_partial
          | :token_verified
          | :unverified

  @type trust_provider :: :dhcp | :netboot | :aws | :gcp | :azure | :token | :none

  @type t :: %__MODULE__{
          id: String.t(),
          hostname: String.t(),
          machine_id: String.t() | nil,
          ssh_pubkey: String.t(),
          key_fingerprint: String.t(),
          age_recipient: String.t(),
          status: status(),
          trust_level: trust_level(),
          trust_provider: trust_provider(),
          trust_evidence: map(),
          role: String.t() | nil,
          datacenter: String.t() | nil,
          metadata: map(),
          previous_keys: [map()],
          created_at: DateTime.t(),
          approved_at: DateTime.t() | nil,
          approved_by: String.t() | nil,
          revoked_at: DateTime.t() | nil,
          revoked_by: String.t() | nil,
          revoke_reason: String.t() | nil
        }

  @enforce_keys [:id, :hostname, :ssh_pubkey, :key_fingerprint, :age_recipient]
  defstruct [
    :id,
    :hostname,
    :machine_id,
    :ssh_pubkey,
    :key_fingerprint,
    :age_recipient,
    :approved_at,
    :approved_by,
    :revoked_at,
    :revoked_by,
    :revoke_reason,
    :role,
    :datacenter,
    status: :pending,
    trust_level: :unverified,
    trust_provider: :none,
    trust_evidence: %{},
    metadata: %{},
    previous_keys: [],
    created_at: nil
  ]

  @valid_statuses ~w(pending approved revoked)a
  @valid_trust_levels ~w(cloud_verified netboot_verified network_verified network_partial token_verified unverified)a
  @valid_trust_providers ~w(dhcp netboot aws gcp azure token none)a

  @doc """
  Computes the SHA256 fingerprint of an SSH public key.
  """
  @spec compute_fingerprint(String.t()) :: {:ok, String.t()} | {:error, :invalid_pubkey}
  def compute_fingerprint(ssh_pubkey) when is_binary(ssh_pubkey) do
    case parse_ssh_pubkey(ssh_pubkey) do
      {:ok, key_data} ->
        hash = :crypto.hash(:sha256, key_data)
        fingerprint = "SHA256:" <> Base.encode64(hash, padding: false)
        {:ok, fingerprint}

      :error ->
        {:error, :invalid_pubkey}
    end
  end

  @doc """
  Validates an SSH ed25519 public key format.
  """
  @spec validate_pubkey(String.t()) :: :ok | {:error, :invalid_pubkey}
  def validate_pubkey(ssh_pubkey) when is_binary(ssh_pubkey) do
    case parse_ssh_pubkey(ssh_pubkey) do
      {:ok, _} -> :ok
      :error -> {:error, :invalid_pubkey}
    end
  end

  @doc """
  Validates an age recipient format (age1...).
  """
  # Bech32 charset enforced to prevent YAML/TOML injection via special chars
  @age_max_len 90
  @age_bech32_re ~r/^age1[qpzry9x8gf2tvdw0s3jn54khce6mua7l]+$/

  @spec validate_age_recipient(String.t()) :: :ok | {:error, :invalid_age_recipient}
  def validate_age_recipient(age_recipient) when is_binary(age_recipient) do
    len = byte_size(age_recipient)

    if len > 10 and len <= @age_max_len and Regex.match?(@age_bech32_re, age_recipient) do
      :ok
    else
      {:error, :invalid_age_recipient}
    end
  end

  @doc """
  Creates a new Host struct from registration parameters.
  """
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(params) when is_map(params) do
    hostname = Map.get(params, :hostname) || Map.get(params, "hostname")
    ssh_pubkey = Map.get(params, :ssh_pubkey) || Map.get(params, "ssh_pubkey")
    age_recipient = Map.get(params, :age_recipient) || Map.get(params, "age_recipient")
    machine_id = Map.get(params, :machine_id) || Map.get(params, "machine_id")
    metadata = Map.get(params, :metadata) || Map.get(params, "metadata", %{})
    role = Map.get(params, :role) || Map.get(metadata, "role")
    datacenter = Map.get(params, :datacenter) || Map.get(metadata, "datacenter")

    with :ok <- validate_required(hostname, ssh_pubkey, age_recipient),
         :ok <- validate_pubkey(ssh_pubkey),
         :ok <- validate_age_recipient(age_recipient),
         {:ok, fingerprint} <- compute_fingerprint(ssh_pubkey) do
      host = %__MODULE__{
        id: generate_uuid(),
        hostname: hostname,
        machine_id: machine_id,
        ssh_pubkey: ssh_pubkey,
        key_fingerprint: fingerprint,
        age_recipient: age_recipient,
        role: role,
        datacenter: datacenter,
        metadata: metadata,
        created_at: DateTime.utc_now()
      }

      {:ok, host}
    end
  end

  @doc """
  Converts a Host struct to a TOML-compatible map.
  """
  @spec to_toml_map(t()) :: map()
  def to_toml_map(%__MODULE__{} = host) do
    %{
      "host" =>
        %{
          "id" => host.id,
          "hostname" => host.hostname,
          "ssh_pubkey" => host.ssh_pubkey,
          "key_fingerprint" => host.key_fingerprint,
          "age_recipient" => host.age_recipient,
          "status" => to_string(host.status),
          "trust_level" => to_string(host.trust_level),
          "trust_provider" => to_string(host.trust_provider),
          "created_at" => format_datetime(host.created_at)
        }
        |> maybe_put("machine_id", host.machine_id)
        |> maybe_put("role", host.role)
        |> maybe_put("datacenter", host.datacenter)
        |> maybe_put("approved_at", format_datetime(host.approved_at))
        |> maybe_put("approved_by", host.approved_by)
        |> maybe_put("revoked_at", format_datetime(host.revoked_at))
        |> maybe_put("revoked_by", host.revoked_by)
        |> maybe_put("revoke_reason", host.revoke_reason)
        |> put_if_nonempty("previous_keys", host.previous_keys)
        |> Map.put("trust_evidence", stringify_map(host.trust_evidence))
        |> Map.put("metadata", stringify_map(host.metadata))
    }
  end

  @doc """
  Creates a Host struct from a parsed TOML map.
  """
  @spec from_toml_map(map()) :: {:ok, t()} | {:error, term()}
  def from_toml_map(%{"host" => data}) do
    try do
      host = %__MODULE__{
        id: Map.fetch!(data, "id"),
        hostname: Map.fetch!(data, "hostname"),
        machine_id: Map.get(data, "machine_id"),
        ssh_pubkey: Map.fetch!(data, "ssh_pubkey"),
        key_fingerprint: Map.fetch!(data, "key_fingerprint"),
        age_recipient: Map.fetch!(data, "age_recipient"),
        status: safe_to_atom(Map.fetch!(data, "status"), @valid_statuses),
        trust_level: safe_to_atom(Map.fetch!(data, "trust_level"), @valid_trust_levels),
        trust_provider: safe_to_atom(Map.fetch!(data, "trust_provider"), @valid_trust_providers),
        trust_evidence: Map.get(data, "trust_evidence", %{}),
        role: Map.get(data, "role"),
        datacenter: Map.get(data, "datacenter"),
        metadata: Map.get(data, "metadata", %{}),
        previous_keys: Map.get(data, "previous_keys", []),
        created_at: parse_datetime(Map.get(data, "created_at")),
        approved_at: parse_datetime(Map.get(data, "approved_at")),
        approved_by: Map.get(data, "approved_by"),
        revoked_at: parse_datetime(Map.get(data, "revoked_at")),
        revoked_by: Map.get(data, "revoked_by"),
        revoke_reason: Map.get(data, "revoke_reason")
      }

      {:ok, host}
    rescue
      e -> {:error, {:invalid_toml_data, Exception.message(e)}}
    end
  end

  def from_toml_map(_), do: {:error, :missing_host_section}

  # Private helpers

  @max_hostname_length 253

  defp validate_required(hostname, ssh_pubkey, age_recipient) do
    cond do
      is_nil(hostname) or hostname == "" ->
        {:error, :hostname_required}

      byte_size(hostname) > @max_hostname_length ->
        {:error, :hostname_too_long}

      not Regex.match?(~r/^[\w\-\.]+$/, hostname) ->
        {:error, :hostname_invalid_chars}

      is_nil(ssh_pubkey) or ssh_pubkey == "" ->
        {:error, :ssh_pubkey_required}

      is_nil(age_recipient) or age_recipient == "" ->
        {:error, :age_recipient_required}

      true ->
        :ok
    end
  end

  defp parse_ssh_pubkey(ssh_pubkey) do
    parts = String.split(ssh_pubkey, " ", parts: 3)

    case parts do
      [_type, base64_data | _] ->
        case Base.decode64(base64_data) do
          {:ok, data} -> {:ok, data}
          :error -> :error
        end

      _ ->
        :error
    end
  end

  defp generate_uuid do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)

    # Set version 4 and variant bits
    c_versioned = (c &&& 0x0FFF) ||| 0x4000
    d_variant = (d &&& 0x3FFF) ||| 0x8000

    :io_lib.format(
      "~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b",
      [a, b, c_versioned, d_variant, e]
    )
    |> to_string()
  end

  defp format_datetime(nil), do: nil
  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_datetime(str) when is_binary(str), do: str

  defp parse_datetime(nil), do: nil
  defp parse_datetime(%DateTime{} = dt), do: dt

  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp safe_to_atom(str, valid_atoms) do
    atom = String.to_existing_atom(str)
    if atom in valid_atoms, do: atom, else: hd(valid_atoms)
  rescue
    ArgumentError -> hd(valid_atoms)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp put_if_nonempty(map, _key, []), do: map
  defp put_if_nonempty(map, key, list), do: Map.put(map, key, list)

  # Exclude structs — DateTime and other structs are not regular enumerable maps
  defp stringify_map(map) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {k, v} -> {to_string(k), stringify_value(v)} end)
  end

  defp stringify_map(other), do: other

  # DateTime must come before the generic is_map/1 guard (structs pass is_map)
  defp stringify_value(%DateTime{} = dt), do: format_datetime(dt)
  defp stringify_value(v) when is_atom(v), do: to_string(v)
  defp stringify_value(v) when is_map(v), do: stringify_map(v)
  defp stringify_value(v), do: v
end
