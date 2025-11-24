defmodule YellowDog.Dns.Zone.Forward do
  @moduledoc """
  Forward zone configuration and management.

  Forward zones delegate DNS queries to upstream resolvers instead of
  performing authoritative resolution. This is useful for:
  - Delegating specific subdomains to external DNS servers
  - Implementing conditional forwarding based on domain names
  - Creating DNS split-brain architectures

  ## Forward Modes

  - `:first` - Try local authoritative resolution first, forward only on NXDOMAIN
  - `:only` - Always forward to upstream, never try local resolution

  ## Examples

      iex> forwarders = [{8, 8, 8, 8}, {1, 1, 1, 1}]
      iex> forward = Forward.new("external.com", forwarders, forward_mode: :only)
      %Forward{name: "external.com", forwarders: [...], forward_mode: :only}

      iex> Forward.validate(forward)
      :ok
  """

  @type forward_mode :: :first | :only
  @type t :: %__MODULE__{
          name: String.t(),
          forwarders: [:inet.ip_address()],
          forward_mode: forward_mode(),
          timeout_ms: non_neg_integer(),
          max_retries: non_neg_integer()
        }

  defstruct [
    :name,
    :forwarders,
    :forward_mode,
    :timeout_ms,
    :max_retries
  ]

  @doc """
  Creates a new forward zone configuration.

  ## Parameters
  - `name` - Zone name (e.g., "external.com")
  - `forwarders` - List of IP addresses (tuples) to forward to
  - `opts` - Optional configuration

  ## Options
  - `:forward_mode` - Forward mode (default: `:only`)
  - `:timeout_ms` - Timeout in milliseconds (default: 5000)
  - `:max_retries` - Maximum retry attempts per forwarder (default: 2)

  ## Examples

      iex> Forward.new("external.com", [{8, 8, 8, 8}, {1, 1, 1, 1}])
      %Forward{name: "external.com", forwarders: [{8, 8, 8, 8}, {1, 1, 1, 1}], ...}
  """
  @spec new(String.t(), [:inet.ip_address()], keyword()) :: t()
  def new(name, forwarders, opts \\ []) do
    %__MODULE__{
      name: name,
      forwarders: forwarders,
      forward_mode: Keyword.get(opts, :forward_mode, :only),
      timeout_ms: Keyword.get(opts, :timeout_ms, 5000),
      max_retries: Keyword.get(opts, :max_retries, 2)
    }
  end

  @doc """
  Validates a forward zone configuration.

  Checks for:
  - Valid zone name
  - At least one forwarder
  - Valid forward mode
  - Reasonable timeout and retry values

  ## Examples

      iex> forward = Forward.new("external.com", [{8, 8, 8, 8}])
      iex> Forward.validate(forward)
      :ok

      iex> forward = Forward.new("", [])
      iex> Forward.validate(forward)
      {:error, :missing_name}
  """
  @spec validate(t()) :: :ok | {:error, atom()}
  def validate(%__MODULE__{} = forward) do
    cond do
      is_nil(forward.name) or forward.name == "" ->
        {:error, :missing_name}

      is_nil(forward.forwarders) or forward.forwarders == [] ->
        {:error, :missing_forwarders}

      forward.forward_mode not in [:first, :only] ->
        {:error, :invalid_forward_mode}

      forward.timeout_ms < 100 or forward.timeout_ms > 30_000 ->
        {:error, :invalid_timeout}

      forward.max_retries < 0 or forward.max_retries > 10 ->
        {:error, :invalid_max_retries}

      true ->
        :ok
    end
  end

  @doc """
  Parses forward zone configuration from a map (typically from TOML).

  ## Parameters
  - `config` - Configuration map

  ## Expected Keys
  - `"name"` - Zone name (required)
  - `"forwarders"` - List of IP address strings (required)
  - `"forward_mode"` - Forward mode string (optional, default: "only")
  - `"timeout_ms"` - Timeout in milliseconds (optional)
  - `"max_retries"` - Maximum retries (optional)

  ## Examples

      iex> config = %{
      ...>   "name" => "external.com",
      ...>   "forwarders" => ["8.8.8.8", "1.1.1.1"],
      ...>   "forward_mode" => "only"
      ...> }
      iex> Forward.parse_config(config)
      {:ok, %Forward{name: "external.com", forwarders: [...], ...}}

      iex> Forward.parse_config(%{})
      {:error, :missing_name}
  """
  @spec parse_config(map()) :: {:ok, t()} | {:error, atom()}
  def parse_config(config) when is_map(config) do
    with {:ok, name} <- fetch_required(config, "name"),
         {:ok, forwarders_str} <- fetch_required(config, "forwarders"),
         {:ok, forwarders} <- parse_forwarders(forwarders_str) do
      opts =
        []
        |> maybe_add_opt(config, "forward_mode", :forward_mode, &parse_forward_mode/1)
        |> maybe_add_opt(config, "timeout_ms", :timeout_ms, &parse_integer/1)
        |> maybe_add_opt(config, "max_retries", :max_retries, &parse_integer/1)

      forward = new(name, forwarders, opts)

      case validate(forward) do
        :ok -> {:ok, forward}
        error -> error
      end
    end
  end

  @doc """
  Converts a forward zone to storage metadata format.

  This allows forward zones to be stored in Zone.Storage alongside
  authoritative zones.

  ## Examples

      iex> forward = Forward.new("external.com", [{8, 8, 8, 8}])
      iex> Forward.to_storage_metadata(forward)
      %{
        type: :forward,
        forwarders: [{8, 8, 8, 8}],
        forward_mode: :only,
        timeout_ms: 5000,
        max_retries: 2
      }
  """
  @spec to_storage_metadata(t()) :: map()
  def to_storage_metadata(%__MODULE__{} = forward) do
    %{
      type: :forward,
      forwarders: forward.forwarders,
      forward_mode: forward.forward_mode,
      timeout_ms: forward.timeout_ms,
      max_retries: forward.max_retries,
      loaded_at: System.system_time(:second)
    }
  end

  @doc """
  Creates a forward zone from storage metadata.

  ## Parameters
  - `zone_name` - The zone name
  - `metadata` - Metadata map from storage

  ## Examples

      iex> metadata = %{
      ...>   type: :forward,
      ...>   forwarders: [{8, 8, 8, 8}],
      ...>   forward_mode: :only
      ...> }
      iex> Forward.from_storage_metadata("external.com", metadata)
      {:ok, %Forward{name: "external.com", ...}}
  """
  @spec from_storage_metadata(String.t(), map()) :: {:ok, t()} | {:error, atom()}
  def from_storage_metadata(zone_name, metadata) when is_map(metadata) do
    if Map.get(metadata, :type) == :forward do
      opts = [
        forward_mode: Map.get(metadata, :forward_mode, :only),
        timeout_ms: Map.get(metadata, :timeout_ms, 5000),
        max_retries: Map.get(metadata, :max_retries, 2)
      ]

      forwarders = Map.get(metadata, :forwarders, [])
      forward = new(zone_name, forwarders, opts)

      case validate(forward) do
        :ok -> {:ok, forward}
        error -> error
      end
    else
      {:error, :not_forward_zone}
    end
  end

  # Private Functions

  defp fetch_required(config, key) do
    case Map.get(config, key) do
      nil -> {:error, String.to_atom("missing_#{key}")}
      value -> {:ok, value}
    end
  end

  defp parse_forwarders(forwarders) when is_list(forwarders) do
    results =
      Enum.map(forwarders, fn
        ip when is_tuple(ip) ->
          {:ok, ip}

        ip_str when is_binary(ip_str) ->
          parse_ip_address(ip_str)

        _ ->
          {:error, :invalid_forwarder}
      end)

    # Check if all parsed successfully
    if Enum.all?(results, &match?({:ok, _}, &1)) do
      ips = Enum.map(results, fn {:ok, ip} -> ip end)
      {:ok, ips}
    else
      {:error, :invalid_forwarders}
    end
  end

  defp parse_forwarders(_), do: {:error, :invalid_forwarders}

  defp parse_ip_address(ip_str) when is_binary(ip_str) do
    charlist = String.to_charlist(ip_str)

    case :inet.parse_ipv4_address(charlist) do
      {:ok, ip} ->
        {:ok, ip}

      {:error, _} ->
        case :inet.parse_ipv6_address(charlist) do
          {:ok, ip} -> {:ok, ip}
          {:error, _} -> {:error, :invalid_ip}
        end
    end
  end

  defp parse_forward_mode("first"), do: {:ok, :first}
  defp parse_forward_mode("only"), do: {:ok, :only}
  defp parse_forward_mode(:first), do: {:ok, :first}
  defp parse_forward_mode(:only), do: {:ok, :only}
  defp parse_forward_mode(_), do: {:error, :invalid_forward_mode}

  defp parse_integer(value) when is_integer(value), do: {:ok, value}

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> {:ok, int}
      _ -> {:error, :invalid_integer}
    end
  end

  defp parse_integer(_), do: {:error, :invalid_integer}

  defp maybe_add_opt(opts, config, config_key, opt_key, parser) do
    case Map.get(config, config_key) do
      nil ->
        opts

      value ->
        case parser.(value) do
          {:ok, parsed} -> Keyword.put(opts, opt_key, parsed)
          {:error, _} -> opts
        end
    end
  end
end
