defmodule YellowDog.Server.Control.Result do
  @moduledoc false

  alias YellowDog.Sync.Bounds
  alias YellowDog.Sync.Codec
  alias YellowDog.Sync.Error

  @max_depth 8
  @max_integer 9_223_372_036_854_775_807
  @absolute_unix_path ~r{(?:\A|[\s"'=,(\[])/[A-Za-z0-9._-]+}u
  @local_file_uri ~r{\bfile:///}iu
  @secret_assignment ~r{\b(?:token|password|api[_-]?key)\s*[:=]\s*\S+}iu
  @authorization_secret ~r{\bauthorization\s*[:=]\s*\S+}iu
  @bearer_secret ~r|\bbearer\s+[A-Za-z0-9._~+/=-]{4,}|iu
  @fixed_atoms MapSet.new([
                 :A,
                 :AAAA,
                 :CNAME,
                 :MX,
                 :NS,
                 :PTR,
                 :SRV,
                 :TXT,
                 :activated,
                 :active,
                 :all,
                 :allow,
                 :answered,
                 :apply,
                 :applied,
                 :applying,
                 :approved,
                 :authoritative,
                 :bound,
                 :completed,
                 :deactivated,
                 :default,
                 :degraded,
                 :delivered,
                 :delivery,
                 :deny,
                 :dhcp,
                 :disabled,
                 :discovered,
                 :down,
                 :expired,
                 :failed,
                 :forward,
                 :forwarded,
                 :global,
                 :healthy,
                 :host,
                 :init,
                 :ipv4,
                 :ipv6,
                 :lease_expired,
                 :lease_granted,
                 :lease_released,
                 :lease_renewed,
                 :link,
                 :local,
                 :managed,
                 :missing,
                 :pending,
                 :provider,
                 :rebinding,
                 :refused,
                 :released,
                 :renewing,
                 :requesting,
                 :require_approval,
                 :resolved,
                 :revoked,
                 :rollback,
                 :route53,
                 :rfc2136,
                 :running,
                 :selecting,
                 :snapshot,
                 :standalone,
                 :static,
                 :stopped,
                 :unavailable,
                 :unhealthy,
                 :unknown,
                 :up,
                 :updated,
                 :use_cloud,
                 :use_local,
                 :validation,
                 :cloudflare
               ])

  @spec normalize(term()) :: {:ok, term()} | {:error, Error.t()}
  def normalize(value) do
    with {:ok, normalized} <- normalize(value, @max_depth),
         {:ok, encoded} <- Codec.encode(normalized),
         {:ok, _encoded} <- Bounds.payload(encoded) do
      {:ok, normalized}
    else
      _ -> invalid_error()
    end
  end

  defp normalize(%DateTime{utc_offset: 0, std_offset: 0} = value, _depth) do
    {:ok, DateTime.to_iso8601(value)}
  end

  defp normalize(value, _depth) when is_struct(value), do: invalid_error()

  defp normalize(value, _depth) when is_binary(value) do
    normalize_text(value)
  end

  defp normalize(value, _depth)
       when is_nil(value) or is_boolean(value),
       do: {:ok, value}

  defp normalize(value, _depth)
       when is_integer(value) and value >= -@max_integer and value <= @max_integer,
       do: {:ok, value}

  defp normalize(value, _depth) when is_float(value) do
    case Jason.encode(value) do
      {:ok, _encoded} -> {:ok, value}
      _ -> invalid_error()
    end
  end

  defp normalize(value, _depth) when is_atom(value) do
    if MapSet.member?(@fixed_atoms, value) do
      {:ok, Atom.to_string(value)}
    else
      invalid_error()
    end
  end

  defp normalize(value, depth) when is_map(value) and depth > 0 do
    with {:ok, _value} <- Bounds.map(value),
         {:ok, entries} <- normalize_map(value, depth - 1) do
      {:ok, Map.new(entries)}
    else
      _ -> invalid_error()
    end
  end

  defp normalize(value, depth) when is_list(value) and depth > 0 do
    with {:ok, values} <- Bounds.list(value) do
      normalize_list(values, depth - 1, [])
    else
      _ -> invalid_error()
    end
  end

  defp normalize(_value, _depth), do: invalid_error()

  defp normalize_map(value, depth) do
    Enum.reduce_while(value, {:ok, %{}, []}, fn {key, nested}, {:ok, seen, entries} ->
      with {:ok, key} <- normalize_key(key),
           false <- Map.has_key?(seen, key),
           {:ok, nested} <- normalize(nested, depth) do
        {:cont, {:ok, Map.put(seen, key, true), [{key, nested} | entries]}}
      else
        _ -> {:halt, invalid_error()}
      end
    end)
    |> case do
      {:ok, _seen, entries} -> {:ok, Enum.sort_by(entries, &elem(&1, 0))}
      error -> error
    end
  end

  defp normalize_key(key) when is_atom(key), do: key |> Atom.to_string() |> normalize_key()

  defp normalize_key(key) when is_binary(key) do
    case normalize_text(key) do
      {:ok, ""} -> invalid_error()
      {:ok, key} -> {:ok, key}
      _ -> invalid_error()
    end
  end

  defp normalize_key(_key), do: invalid_error()

  defp normalize_text(value) do
    with {:ok, value} <- Bounds.message(value),
         false <- sensitive_text?(value) do
      {:ok, value}
    else
      _invalid -> invalid_error()
    end
  end

  defp sensitive_text?(value) do
    Enum.any?(
      [
        @absolute_unix_path,
        @local_file_uri,
        @secret_assignment,
        @authorization_secret,
        @bearer_secret
      ],
      &Regex.match?(&1, value)
    )
  end

  defp normalize_list([], _depth, values), do: {:ok, Enum.reverse(values)}

  defp normalize_list([value | rest], depth, values) do
    with {:ok, value} <- normalize(value, depth) do
      normalize_list(rest, depth, [value | values])
    end
  end

  defp invalid_error, do: {:error, Error.new(:invalid, "invalid value", %{})}
end
