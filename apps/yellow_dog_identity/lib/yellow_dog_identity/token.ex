defmodule YellowDogIdentity.Token do
  import Bitwise

  @moduledoc """
  Provisioning token for out-of-band host registration.

  Tokens are pre-generated, single-use (or limited-use), time-limited credentials
  that establish `token_verified` trust level when no DHCP or cloud attestation
  is available.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          token_hash: String.t(),
          hostname_pattern: String.t(),
          role: String.t() | nil,
          max_uses: pos_integer(),
          use_count: non_neg_integer(),
          expires_at: DateTime.t(),
          created_by: String.t(),
          created_at: DateTime.t()
        }

  @enforce_keys [:id, :token_hash, :hostname_pattern, :max_uses, :expires_at, :created_by]
  defstruct [
    :id,
    :token_hash,
    :hostname_pattern,
    :role,
    :expires_at,
    :created_by,
    max_uses: 1,
    use_count: 0,
    created_at: nil
  ]

  @token_bytes 32

  @doc """
  Creates a new provisioning token, returning both the token struct and the raw token value.

  The raw token is returned only once — it is not stored. Only the bcrypt hash is persisted.
  """
  @spec create(map()) :: {:ok, t(), raw_token :: String.t()} | {:error, term()}
  def create(params) when is_map(params) do
    hostname_pattern = Map.get(params, :hostname_pattern, "*")
    max_uses = Map.get(params, :max_uses, 1)
    role = Map.get(params, :role)
    created_by = Map.get(params, :created_by, "system")
    ttl_seconds = Map.get(params, :ttl_seconds, 3600)

    expires_at = DateTime.add(DateTime.utc_now(), ttl_seconds, :second)

    # Generate raw token
    raw_token =
      :crypto.strong_rand_bytes(@token_bytes)
      |> Base.url_encode64(padding: false)

    # Hash with SHA-256 (bcrypt is too slow for token verification in hot path)
    token_hash = hash_token(raw_token)

    token = %__MODULE__{
      id: generate_uuid(),
      token_hash: token_hash,
      hostname_pattern: hostname_pattern,
      role: role,
      max_uses: max_uses,
      expires_at: expires_at,
      created_by: created_by,
      created_at: DateTime.utc_now()
    }

    {:ok, token, raw_token}
  end

  @doc """
  Verifies a raw token against a token struct.
  """
  @spec verify(t(), String.t(), String.t()) :: :ok | {:error, term()}
  def verify(%__MODULE__{} = token, raw_token, hostname) do
    cond do
      # Use constant-time comparison to prevent timing-based token enumeration.
      not :crypto.hash_equals(hash_token(raw_token), token.token_hash) ->
        {:error, :invalid_token}

      DateTime.compare(DateTime.utc_now(), token.expires_at) == :gt ->
        {:error, :token_expired}

      token.use_count >= token.max_uses ->
        {:error, :token_exhausted}

      not hostname_matches?(hostname, token.hostname_pattern) ->
        {:error, :hostname_mismatch}

      true ->
        :ok
    end
  end

  @doc """
  Increments the use count of a token.
  """
  @spec increment_use(t()) :: t()
  def increment_use(%__MODULE__{} = token) do
    %{token | use_count: token.use_count + 1}
  end

  @doc """
  Checks if a token is still valid (not expired, not exhausted).
  """
  @spec valid?(t()) :: boolean()
  def valid?(%__MODULE__{} = token) do
    DateTime.compare(DateTime.utc_now(), token.expires_at) != :gt and
      token.use_count < token.max_uses
  end

  @doc """
  Converts a Token struct to a TOML-compatible map.
  """
  @spec to_toml_map(t()) :: map()
  def to_toml_map(%__MODULE__{} = token) do
    %{
      "token" =>
        %{
          "id" => token.id,
          "token_hash" => token.token_hash,
          "hostname_pattern" => token.hostname_pattern,
          "max_uses" => token.max_uses,
          "use_count" => token.use_count,
          "expires_at" => DateTime.to_iso8601(token.expires_at),
          "created_by" => token.created_by,
          "created_at" => DateTime.to_iso8601(token.created_at)
        }
        |> maybe_put("role", token.role)
    }
  end

  @doc """
  Creates a Token struct from a parsed TOML map.
  """
  @spec from_toml_map(map()) :: {:ok, t()} | {:error, term()}
  def from_toml_map(%{"token" => data}) do
    try do
      token = %__MODULE__{
        id: Map.fetch!(data, "id"),
        token_hash: Map.fetch!(data, "token_hash"),
        hostname_pattern: Map.fetch!(data, "hostname_pattern"),
        role: Map.get(data, "role"),
        max_uses: Map.fetch!(data, "max_uses"),
        use_count: Map.get(data, "use_count", 0),
        expires_at: parse_datetime!(Map.fetch!(data, "expires_at")),
        created_by: Map.fetch!(data, "created_by"),
        created_at: parse_datetime!(Map.get(data, "created_at", DateTime.to_iso8601(DateTime.utc_now())))
      }

      {:ok, token}
    rescue
      e -> {:error, {:invalid_toml_data, Exception.message(e)}}
    end
  end

  def from_toml_map(_), do: {:error, :missing_token_section}

  # Private helpers

  defp hash_token(raw_token) do
    :crypto.hash(:sha256, raw_token) |> Base.encode64(padding: false)
  end

  @doc false
  def hostname_matches?(_hostname, "*"), do: true

  def hostname_matches?(hostname, pattern) do
    regex_pattern =
      pattern
      |> Regex.escape()
      |> String.replace("\\*", ".*")
      |> then(&("^" <> &1 <> "$"))

    Regex.match?(~r/#{regex_pattern}/, hostname)
  end

  defp generate_uuid do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)
    c_versioned = (c &&& 0x0FFF) ||| 0x4000
    d_variant = (d &&& 0x3FFF) ||| 0x8000

    :io_lib.format(
      "~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b",
      [a, b, c_versioned, d_variant, e]
    )
    |> to_string()
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp parse_datetime!(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> raise "Invalid datetime: #{str}"
    end
  end
end
