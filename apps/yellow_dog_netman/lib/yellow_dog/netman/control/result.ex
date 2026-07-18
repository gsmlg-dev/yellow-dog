defmodule YellowDog.Netman.Control.Result do
  @moduledoc false

  alias YellowDog.Sync.Bounds
  alias YellowDog.Sync.Codec
  alias YellowDog.Sync.Error

  @max_depth 8
  @max_integer 9_223_372_036_854_775_807
  @fixed_atoms MapSet.new([
                 :activated,
                 :active,
                 :apply,
                 :applied,
                 :applying,
                 :bound,
                 :completed,
                 :degraded,
                 :deactivated,
                 :delivered,
                 :delivery,
                 :dhcp,
                 :disabled,
                 :down,
                 :failed,
                 :global,
                 :healthy,
                 :host,
                 :init,
                 :ipv4,
                 :ipv6,
                 :link,
                 :managed,
                 :observe,
                 :observe_first,
                 :pending,
                 :rebinding,
                 :renewing,
                 :requesting,
                 :resolved,
                 :rollback,
                 :selecting,
                 :static,
                 :unavailable,
                 :unhealthy,
                 :unknown,
                 :up,
                 :validation
               ])
  @forbidden_keys MapSet.new(
                    ~w(path local_path file_path filename pid port ref reference socket ets table handle)
                  )

  @spec normalize(term()) :: {:ok, term()} | {:error, Error.t()}
  def normalize(value) do
    with {:ok, normalized} <- normalize_value(value, @max_depth),
         {:ok, encoded} <- Codec.encode(normalized),
         {:ok, _encoded} <- Bounds.payload(encoded) do
      {:ok, normalized}
    else
      _ -> invalid_error()
    end
  end

  defp normalize_value(%DateTime{utc_offset: 0, std_offset: 0} = value, _depth),
    do: {:ok, DateTime.to_iso8601(value)}

  defp normalize_value(value, _depth) when is_struct(value), do: invalid_error()

  defp normalize_value(value, _depth) when is_binary(value) do
    with {:ok, value} <- Bounds.message(value),
         false <- unsafe_text?(value) do
      {:ok, value}
    else
      _ -> invalid_error()
    end
  end

  defp normalize_value(value, _depth) when is_nil(value) or is_boolean(value), do: {:ok, value}

  defp normalize_value(value, _depth)
       when is_integer(value) and value >= -@max_integer and value <= @max_integer,
       do: {:ok, value}

  defp normalize_value(value, _depth) when is_float(value) do
    if match?({:ok, _}, Jason.encode(value)), do: {:ok, value}, else: invalid_error()
  end

  defp normalize_value(value, _depth) when is_atom(value) do
    if MapSet.member?(@fixed_atoms, value),
      do: {:ok, Atom.to_string(value)},
      else: invalid_error()
  end

  defp normalize_value(value, depth) when is_map(value) and depth > 0 do
    with {:ok, _value} <- Bounds.map(value),
         {:ok, entries} <- normalize_map(value, depth - 1) do
      {:ok, Map.new(entries)}
    else
      _ -> invalid_error()
    end
  end

  defp normalize_value(value, depth) when is_list(value) and depth > 0 do
    with {:ok, values} <- Bounds.list(value) do
      normalize_list(values, depth - 1, [])
    else
      _ -> invalid_error()
    end
  end

  defp normalize_value(_value, _depth), do: invalid_error()

  defp normalize_map(value, depth) do
    Enum.reduce_while(value, {:ok, %{}, []}, fn {key, nested}, {:ok, seen, entries} ->
      with {:ok, key} <- normalize_key(key),
           false <- Map.has_key?(seen, key),
           false <- MapSet.member?(@forbidden_keys, key),
           {:ok, nested} <- normalize_value(nested, depth) do
        {:cont, {:ok, Map.put(seen, key, true), [{key, nested} | entries]}}
      else
        _ -> {:halt, invalid_error()}
      end
    end)
    |> case do
      {:ok, _seen, entries} -> {:ok, entries}
      error -> error
    end
  end

  defp normalize_list([], _depth, values), do: {:ok, Enum.reverse(values)}

  defp normalize_list([value | rest], depth, values) do
    with {:ok, value} <- normalize_value(value, depth) do
      normalize_list(rest, depth, [value | values])
    end
  end

  defp normalize_list(_value, _depth, _values), do: invalid_error()

  defp normalize_key(key) when is_atom(key), do: key |> Atom.to_string() |> normalize_key()

  defp normalize_key(key) when is_binary(key) do
    with {:ok, key} <- Bounds.message(key),
         true <- key != "" do
      {:ok, key}
    else
      _ -> invalid_error()
    end
  end

  defp normalize_key(_key), do: invalid_error()

  defp unsafe_text?(value) do
    cond do
      Regex.match?(~r{(?:file|unix)://}i, value) ->
        true

      secret_assignment?(value) ->
        true

      true ->
        case http_uri_status(value) do
          :safe -> false
          :unsafe -> true
          :not_http -> unix_path?(value) or windows_path?(value)
        end
    end
  end

  defp http_uri_status(value) do
    case URI.new(value) do
      {:ok, %URI{scheme: scheme, host: host, userinfo: nil}}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        :safe

      {:ok, %URI{scheme: scheme}} when scheme in ["http", "https"] ->
        :unsafe

      _other ->
        :not_http
    end
  end

  defp unix_path?(value) do
    Regex.match?(~r/(?<![A-Za-z0-9\/])\/(?!\/)[^\s)\]}>,"']+/, value) or
      Regex.match?(~r/(?<![:\/])\/{2,}(?=[^\/\s])/, value)
  end

  defp windows_path?(value) do
    Regex.match?(~r/(?<![A-Za-z0-9])[A-Za-z]:[\\\/][^\s)\]}>,"']+/, value) or
      Regex.match?(~r/(?:\A|[^A-Za-z0-9\\])\\\\[^\\\s]+\\[^\s]+/, value)
  end

  defp secret_assignment?(value) do
    Regex.match?(~r/(?:password|passwd|token|secret|authorization|credential)\s*=/i, value)
  end

  defp invalid_error, do: {:error, Error.new(:invalid, "invalid value", %{})}
end
