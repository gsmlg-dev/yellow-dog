defmodule YellowDog.NetmanAgent.Bootstrap do
  @moduledoc false

  alias YellowDog.Sync.Bounds

  @required_options [:management_url, :management_token, :netman_id, :data_dir]
  @allowed_options @required_options ++ [:reconnect_initial_ms, :reconnect_max_ms]
  @default_reconnect_initial_ms 1_000
  @default_reconnect_max_ms 30_000
  @max_reconnect_ms 86_400_000

  @type t :: %{
          management_url: String.t(),
          management_token: String.t(),
          netman_id: String.t(),
          data_dir: Path.t(),
          reconnect_initial_ms: pos_integer(),
          reconnect_max_ms: pos_integer()
        }

  @spec validate(term()) :: {:ok, t()} | :error
  def validate(opts) when is_list(opts) do
    with true <- Keyword.keyword?(opts),
         keys = Keyword.keys(opts),
         true <- length(keys) == length(Enum.uniq(keys)),
         true <- Enum.all?(keys, &(&1 in @allowed_options)),
         true <- Enum.all?(@required_options, &Keyword.has_key?(opts, &1)),
         {:ok, management_url} <- management_url(Keyword.get(opts, :management_url)),
         {:ok, management_token} <- nonempty_message(Keyword.get(opts, :management_token)),
         {:ok, netman_id} <- netman_id(Keyword.get(opts, :netman_id)),
         {:ok, data_dir} <- absolute_data_dir(Keyword.get(opts, :data_dir)),
         {:ok, {reconnect_initial_ms, reconnect_max_ms}} <- reconnect_bounds(opts) do
      {:ok,
       %{
         management_url: management_url,
         management_token: management_token,
         netman_id: netman_id,
         data_dir: data_dir,
         reconnect_initial_ms: reconnect_initial_ms,
         reconnect_max_ms: reconnect_max_ms
       }}
    else
      _invalid -> :error
    end
  end

  def validate(_opts), do: :error

  defp management_url(value) when is_binary(value) do
    with {:ok,
          %URI{
            scheme: "https",
            host: host,
            port: port,
            userinfo: nil,
            query: nil,
            fragment: nil
          }} <- URI.new(value),
         true <- valid_management_host?(host),
         true <- explicit_port?(value, host),
         true <- is_integer(port) and port in 1..65_535 do
      {:ok, value}
    else
      _invalid -> :error
    end
  end

  defp management_url(_value), do: :error

  defp valid_management_host?(host) when is_binary(host) and host != "" do
    valid_ip_address?(host) or valid_dns_host?(host)
  end

  defp valid_management_host?(_host), do: false

  defp explicit_port?(value, host) do
    case :uri_string.parse(value) do
      %{scheme: scheme, host: ^host, port: port}
      when is_binary(scheme) and is_integer(port) ->
        String.downcase(scheme, :ascii) == "https"

      _invalid ->
        false
    end
  end

  defp valid_ip_address?(host) do
    match?({:ok, _address}, :inet.parse_address(String.to_charlist(host)))
  end

  defp valid_dns_host?(host) when byte_size(host) <= 253 do
    host
    |> String.split(".", trim: false)
    |> Enum.all?(&valid_dns_label?/1)
  end

  defp valid_dns_host?(_host), do: false

  defp valid_dns_label?(label) when byte_size(label) in 1..63 do
    Regex.match?(~r/\A[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?\z/, label)
  end

  defp valid_dns_label?(_label), do: false

  defp nonempty_message(value) do
    with {:ok, value} <- Bounds.message(value),
         true <- value != "" do
      {:ok, value}
    else
      _invalid -> :error
    end
  end

  defp netman_id(value) do
    with {:ok, value} <- Bounds.id(value),
         true <- value != "",
         true <- value not in [".", ".."],
         false <- String.contains?(value, ["/", "\\"]),
         false <- Regex.match?(~r/\A[A-Za-z]:/, value),
         normalized when is_binary(normalized) <- :unicode.characters_to_nfkc_binary(value),
         true <- normalized == value,
         false <- Regex.match?(~r/\p{C}/u, value) do
      {:ok, value}
    else
      _invalid -> :error
    end
  rescue
    _exception -> :error
  end

  defp absolute_data_dir(value) when is_binary(value) do
    expanded = Path.expand(value)

    if Path.type(value) == :absolute and expanded == value,
      do: {:ok, value},
      else: :error
  end

  defp absolute_data_dir(_value), do: :error

  defp reconnect_bounds(opts) do
    initial = Keyword.get(opts, :reconnect_initial_ms)
    maximum = Keyword.get(opts, :reconnect_max_ms)

    case {initial, maximum} do
      {nil, nil} ->
        {:ok, {@default_reconnect_initial_ms, @default_reconnect_max_ms}}

      {initial, maximum}
      when is_integer(initial) and initial > 0 and initial <= @max_reconnect_ms and
             is_integer(maximum) and maximum >= initial and maximum <= @max_reconnect_ms ->
        {:ok, {initial, maximum}}

      _invalid ->
        :error
    end
  end
end
