defmodule YellowDog.Console.Validators do
  @moduledoc """
  Validation functions for configuration values.
  Provides reusable validators for IP addresses, ports, ranges, etc.
  """

  import Bitwise

  alias YellowDog.Console.Settings.AddressPool

  @doc """
  Validates an IP address for a specific protocol.

  ## Parameters
    - address: IP address string
    - protocol: `:ipv4` or `:ipv6`

  ## Returns
    - `:ok` if valid
    - `{:error, message}` if invalid

  ## Examples

      iex> YellowDog.Console.Validators.validate_ip("192.168.1.1", :ipv4)
      :ok

      iex> YellowDog.Console.Validators.validate_ip("256.1.1.1", :ipv4)
      {:error, "Invalid IP address format"}

      iex> YellowDog.Console.Validators.validate_ip("::1", :ipv6)
      :ok
  """
  @spec validate_ip(String.t(), :ipv4 | :ipv6) :: :ok | {:error, String.t()}
  def validate_ip(address, protocol) when is_binary(address) do
    case :inet.parse_address(to_charlist(address)) do
      {:ok, {a, b, c, d}} when protocol == :ipv4 ->
        # Verify format to catch incomplete addresses like "192.168.1"
        expected = "#{a}.#{b}.#{c}.#{d}"
        if address == expected, do: :ok, else: {:error, "must be a valid IPv4 address"}

      {:ok, {_, _, _, _}} when protocol == :ipv6 ->
        {:error, "must be a valid IPv6 address"}

      {:ok, {_, _, _, _, _, _, _, _}} when protocol == :ipv6 ->
        :ok

      {:ok, {_, _, _, _, _, _, _, _}} when protocol == :ipv4 ->
        {:error, "must be a valid IPv4 address"}

      {:error, :einval} ->
        {:error, "must be a valid #{protocol} address"}
    end
  end

  @doc """
  Validates a port number.

  ## Parameters
    - port: Port number (integer)

  ## Returns
    - `:ok` if valid (1-65535)
    - `{:error, message}` if invalid

  ## Examples

      iex> YellowDog.Console.Validators.validate_port(53)
      :ok

      iex> YellowDog.Console.Validators.validate_port(99999)
      {:error, "Port must be between 1 and 65535"}
  """
  @spec validate_port(integer()) :: :ok | {:error, String.t()}
  def validate_port(port) when is_integer(port) do
    if port >= 1 and port <= 65_535 do
      :ok
    else
      {:error, "Port must be between 1 and 65535"}
    end
  end

  @doc """
  Validates an IP address range.

  Checks that:
  - Both IPs are valid for the protocol
  - Start IP < End IP

  ## Parameters
    - start_ip: Starting IP address string
    - end_ip: Ending IP address string
    - protocol: `:ipv4` or `:ipv6`

  ## Returns
    - `:ok` if valid
    - `{:error, message}` if invalid

  ## Examples

      iex> YellowDog.Console.Validators.validate_pool_range("192.168.1.100", "192.168.1.200", :ipv4)
      :ok

      iex> YellowDog.Console.Validators.validate_pool_range("192.168.1.200", "192.168.1.100", :ipv4)
      {:error, "Range start must be less than range end"}
  """
  @spec validate_pool_range(String.t(), String.t(), :ipv4 | :ipv6) ::
          :ok | {:error, String.t()}
  def validate_pool_range(start_ip, end_ip, protocol)
      when is_binary(start_ip) and is_binary(end_ip) do
    with :ok <- validate_ip(start_ip, protocol),
         :ok <- validate_ip(end_ip, protocol),
         {:ok, start_tuple} <- :inet.parse_address(to_charlist(start_ip)),
         {:ok, end_tuple} <- :inet.parse_address(to_charlist(end_ip)) do
      compare_ip_addresses(start_tuple, end_tuple)
    end
  end

  @doc """
  Validates a CIDR notation network address.

  ## Parameters
    - cidr: CIDR notation string (e.g., "10.100.0.0/20" or "2001:db8::/32")
    - protocol: `:ipv4` or `:ipv6`

  ## Returns
    - `:ok` if valid
    - `{:error, message}` if invalid

  ## Examples

      iex> YellowDog.Console.Validators.validate_cidr("10.100.0.0/20", :ipv4)
      :ok

      iex> YellowDog.Console.Validators.validate_cidr("2001:db8::/32", :ipv6)
      :ok

      iex> YellowDog.Console.Validators.validate_cidr("10.100.0.0/33", :ipv4)
      {:error, "Invalid CIDR prefix length"}
  """
  @spec validate_cidr(String.t(), :ipv4 | :ipv6) :: :ok | {:error, String.t()}
  def validate_cidr(cidr, protocol) when is_binary(cidr) do
    case String.split(cidr, "/") do
      [ip, prefix_str] ->
        with :ok <- validate_ip(ip, protocol),
             {prefix, ""} <- Integer.parse(prefix_str),
             :ok <- validate_prefix_length(prefix, protocol) do
          :ok
        else
          :error -> {:error, "Invalid CIDR prefix"}
          {:error, msg} -> {:error, msg}
          {_prefix, _remainder} -> {:error, "Invalid CIDR prefix"}
        end

      _ ->
        {:error, "Invalid CIDR format. Use: address/prefix (e.g., 10.0.0.0/24)"}
    end
  end

  defp validate_prefix_length(prefix, :ipv4) when prefix >= 0 and prefix <= 32, do: :ok
  defp validate_prefix_length(prefix, :ipv6) when prefix >= 0 and prefix <= 128, do: :ok
  defp validate_prefix_length(_, _), do: {:error, "Invalid CIDR prefix length"}

  @doc """
  Checks for overlapping address pools.

  ## Parameters
    - pools: List of AddressPool structs
    - protocol: `:ipv4` or `:ipv6`

  ## Returns
    - `:ok` if no overlaps
    - `{:error, message}` if overlaps detected

  ## Examples

      iex> pool1 = %{name: "Pool1", range_start: "192.168.1.100", range_end: "192.168.1.150"}
      iex> pool2 = %{name: "Pool2", range_start: "192.168.1.200", range_end: "192.168.1.250"}
      iex> YellowDog.Console.Validators.check_overlapping_pools([pool1, pool2], :ipv4)
      :ok
  """
  @spec check_overlapping_pools([AddressPool.t()], :ipv4 | :ipv6) ::
          :ok | {:error, String.t()}
  def check_overlapping_pools(pools, _protocol) when is_list(pools) do
    pool_ranges =
      pools
      |> Enum.map(fn pool ->
        {:ok, start_tuple} = :inet.parse_address(to_charlist(pool.range_start))
        {:ok, end_tuple} = :inet.parse_address(to_charlist(pool.range_end))
        {pool.name, ip_to_integer(start_tuple), ip_to_integer(end_tuple)}
      end)
      |> Enum.sort_by(fn {_name, start, _end} -> start end)

    case find_overlapping_ranges(pool_ranges) do
      nil -> :ok
      {pool1, pool2} -> {:error, "Pool '#{pool1}' overlaps with pool '#{pool2}'"}
    end
  end

  @doc """
  Validates a DNS domain name per RFC 1035.

  ## Rules
    - Total length max 253 characters
    - Labels separated by dots, each max 63 characters
    - Labels contain alphanumeric characters and hyphens
    - Labels cannot start or end with a hyphen
    - Wildcard `*` allowed only as first label

  ## Examples

      iex> YellowDog.Console.Validators.validate_domain_name("example.com")
      :ok

      iex> YellowDog.Console.Validators.validate_domain_name("*.example.com")
      :ok

      iex> YellowDog.Console.Validators.validate_domain_name("-invalid.com")
      {:error, "Label cannot start or end with a hyphen"}
  """
  @spec validate_domain_name(String.t()) :: :ok | {:error, String.t()}
  def validate_domain_name(name) when is_binary(name) do
    name = String.trim_trailing(name, ".")

    cond do
      name == "" ->
        {:error, "Domain name cannot be empty"}

      byte_size(name) > 253 ->
        {:error, "Domain name exceeds 253 characters"}

      true ->
        labels = String.split(name, ".")
        validate_labels(labels)
    end
  end

  defp validate_labels([]), do: {:error, "Domain name cannot be empty"}

  defp validate_labels(["*" | rest]) do
    # Wildcard only as first label
    validate_labels_strict(rest)
  end

  defp validate_labels(labels), do: validate_labels_strict(labels)

  defp validate_labels_strict([]), do: :ok

  defp validate_labels_strict([label | rest]) do
    cond do
      label == "" ->
        {:error, "Empty label in domain name"}

      byte_size(label) > 63 ->
        {:error, "Label exceeds 63 characters"}

      String.starts_with?(label, "-") or String.ends_with?(label, "-") ->
        {:error, "Label cannot start or end with a hyphen"}

      not Regex.match?(~r/^[a-zA-Z0-9_-]+$/, label) ->
        {:error, "Label contains invalid characters (allowed: a-z, 0-9, hyphen, underscore)"}

      true ->
        validate_labels_strict(rest)
    end
  end

  @doc """
  Validates a DNS TTL value.

  TTL must be between 0 and 2^31 - 1 (2147483647) per RFC 2181.

  ## Examples

      iex> YellowDog.Console.Validators.validate_ttl(3600)
      :ok

      iex> YellowDog.Console.Validators.validate_ttl(-1)
      {:error, "TTL must be between 0 and 2147483647"}
  """
  @max_ttl 2_147_483_647

  @spec validate_ttl(integer()) :: :ok | {:error, String.t()}
  def validate_ttl(ttl) when is_integer(ttl) and ttl >= 0 and ttl <= @max_ttl, do: :ok
  def validate_ttl(_), do: {:error, "TTL must be between 0 and 2147483647"}

  @doc """
  Validates an MX priority value.

  Priority must be between 0 and 65535.

  ## Examples

      iex> YellowDog.Console.Validators.validate_mx_priority(10)
      :ok

      iex> YellowDog.Console.Validators.validate_mx_priority(70000)
      {:error, "MX priority must be between 0 and 65535"}
  """
  @spec validate_mx_priority(integer()) :: :ok | {:error, String.t()}
  def validate_mx_priority(priority)
      when is_integer(priority) and priority >= 0 and priority <= 65_535,
      do: :ok

  def validate_mx_priority(_), do: {:error, "MX priority must be between 0 and 65535"}

  @doc """
  Validates an SRV record.

  ## Parameters
    - priority: 0-65535
    - weight: 0-65535
    - port: 1-65535
    - target: valid domain name

  ## Examples

      iex> YellowDog.Console.Validators.validate_srv(10, 20, 443, "server.example.com")
      :ok
  """
  @spec validate_srv(integer(), integer(), integer(), String.t()) :: :ok | {:error, String.t()}
  def validate_srv(priority, weight, port, target) do
    with :ok <- validate_uint16(priority, "SRV priority"),
         :ok <- validate_uint16(weight, "SRV weight"),
         :ok <- validate_port(port),
         :ok <- validate_domain_name(target) do
      :ok
    end
  end

  defp validate_uint16(val, _label) when is_integer(val) and val >= 0 and val <= 65_535, do: :ok
  defp validate_uint16(_, label), do: {:error, "#{label} must be between 0 and 65535"}

  # Private Functions

  defp compare_ip_addresses(start_tuple, end_tuple) do
    if ip_to_integer(start_tuple) < ip_to_integer(end_tuple) do
      :ok
    else
      {:error, "Range start must be less than range end"}
    end
  end

  defp ip_to_integer({a, b, c, d}) do
    (a <<< 24) + (b <<< 16) + (c <<< 8) + d
  end

  defp ip_to_integer({a, b, c, d, e, f, g, h}) do
    (a <<< 112) + (b <<< 96) + (c <<< 80) + (d <<< 64) +
      (e <<< 48) + (f <<< 32) + (g <<< 16) + h
  end

  defp find_overlapping_ranges([]), do: nil
  defp find_overlapping_ranges([_]), do: nil

  defp find_overlapping_ranges([{name1, _start1, end1}, {name2, start2, end2} | rest]) do
    if end1 >= start2 do
      {name1, name2}
    else
      find_overlapping_ranges([{name2, start2, end2} | rest])
    end
  end
end
