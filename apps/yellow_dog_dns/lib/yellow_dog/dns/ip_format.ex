defmodule YellowDog.Dns.IpFormat do
  @moduledoc false

  @doc """
  Formats an IP address tuple to a human-readable string.

  Returns the string as-is if already a binary, or `inspect/1` for other types.
  """
  @spec format(term()) :: String.t()
  def format(ip) when is_tuple(ip), do: ip |> :inet.ntoa() |> to_string()
  def format(ip) when is_binary(ip), do: ip
  def format(other), do: inspect(other)
end
