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
          label: String.t(),
          token_hash: String.t(),
          hostname_pattern: String.t(),
          role: String.t() | nil,
          max_uses: pos_integer(),
          use_count: non_neg_integer(),
          expires_at: DateTime.t() | nil,
          revoked_at: DateTime.t() | nil,
          created_by: String.t(),
          created_at: DateTime.t()
        }

  @enforce_keys [:id, :token_hash, :hostname_pattern, :max_uses, :expires_at, :created_by]
  defstruct [
    :id,
    :label,
    :token_hash,
    :hostname_pattern,
    :role,
    :expires_at,
    :revoked_at,
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
    id = param(params, :id) || generate_uuid()

    with {:ok, expires_at} <- token_expiry(params) do
      raw_token =
        :crypto.strong_rand_bytes(@token_bytes)
        |> Base.url_encode64(padding: false)

      token = %__MODULE__{
        id: id,
        label: param(params, :label) || id,
        token_hash: hash_token(raw_token),
        hostname_pattern: param(params, :hostname_pattern) || "*",
        role: param(params, :role),
        max_uses: param(params, :max_uses) || 1,
        expires_at: expires_at,
        created_by: param(params, :created_by) || "system",
        created_at: DateTime.utc_now()
      }

      {:ok, token, raw_token}
    end
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

      not is_nil(token.revoked_at) ->
        {:error, :token_revoked}

      expired?(token) ->
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
    is_nil(token.revoked_at) and not expired?(token) and token.use_count < token.max_uses
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
          "label" => token.label,
          "token_hash" => token.token_hash,
          "hostname_pattern" => token.hostname_pattern,
          "max_uses" => token.max_uses,
          "use_count" => token.use_count,
          "expires_at" => format_datetime(token.expires_at),
          "created_by" => token.created_by,
          "created_at" => DateTime.to_iso8601(token.created_at)
        }
        |> maybe_put("role", token.role)
        |> maybe_put("revoked_at", format_optional_datetime(token.revoked_at))
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
        label: Map.get(data, "label", Map.fetch!(data, "id")),
        token_hash: Map.fetch!(data, "token_hash"),
        hostname_pattern: Map.fetch!(data, "hostname_pattern"),
        role: Map.get(data, "role"),
        max_uses: Map.fetch!(data, "max_uses"),
        use_count: Map.get(data, "use_count", 0),
        expires_at: parse_optional_datetime!(Map.fetch!(data, "expires_at")),
        revoked_at: parse_optional_datetime!(Map.get(data, "revoked_at")),
        created_by: Map.fetch!(data, "created_by"),
        created_at:
          parse_datetime!(Map.get(data, "created_at", DateTime.to_iso8601(DateTime.utc_now())))
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

  defp param(params, key), do: Map.get(params, key) || Map.get(params, Atom.to_string(key))

  defp token_expiry(params) do
    case Map.fetch(params, :expires_at) do
      {:ok, value} -> normalize_expiry(value)
      :error -> token_expiry_from_string_key(params)
    end
  end

  defp token_expiry_from_string_key(params) do
    case Map.fetch(params, "expires_at") do
      {:ok, value} ->
        normalize_expiry(value)

      :error ->
        {:ok, DateTime.add(DateTime.utc_now(), param(params, :ttl_seconds) || 3600, :second)}
    end
  end

  defp normalize_expiry(nil), do: {:ok, nil}
  defp normalize_expiry(%DateTime{} = value), do: {:ok, value}

  defp normalize_expiry(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} -> {:ok, datetime}
      _ -> {:error, :invalid_expiry}
    end
  end

  defp normalize_expiry(_value), do: {:error, :invalid_expiry}

  defp expired?(%__MODULE__{expires_at: nil}), do: false

  defp expired?(%__MODULE__{expires_at: %DateTime{} = expires_at}),
    do: DateTime.compare(DateTime.utc_now(), expires_at) == :gt

  defp format_datetime(nil), do: ""
  defp format_datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp format_optional_datetime(nil), do: nil
  defp format_optional_datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)

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

  defp parse_optional_datetime!(nil), do: nil
  defp parse_optional_datetime!(""), do: nil
  defp parse_optional_datetime!(value), do: parse_datetime!(value)
end
