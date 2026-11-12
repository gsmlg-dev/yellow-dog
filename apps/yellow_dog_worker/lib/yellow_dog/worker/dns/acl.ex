defmodule YellowDog.Worker.Dns.Acl do
  @moduledoc """
  Source-address ACL for Worker DNS queries. An empty rule list denies everyone.
  """

  import Bitwise

  @type t :: %__MODULE__{rules: [{4 | 6, non_neg_integer(), non_neg_integer()}]}
  defstruct rules: []

  @spec compile([String.t()]) :: {:ok, t()}
  def compile(cidrs) when is_list(cidrs), do: {:ok, %__MODULE__{rules: Enum.map(cidrs, &rule/1)}}

  @spec allowed?(t(), :inet.ip_address()) :: boolean()
  def allowed?(%__MODULE__{rules: rules}, ip) do
    {family, value} = normalize(ip)
    Enum.any?(rules, fn {f, net, mask} -> f == family and (value &&& mask) == net end)
  end

  # ConfigSpec canonicalises v4-mapped CIDRs to IPv4 and rejects prefixes beyond
  # the family width; this still computes masks with the width of the family
  # the rule is matched in (a v4-mapped prefix counts its last 32 bits) and
  # clamps the prefix instead of crashing.
  defp rule(cidr) do
    [addr, len] = String.split(cidr, "/", parts: 2)
    {:ok, ip} = :inet.parse_address(String.to_charlist(addr))
    {family, value} = normalize(ip)
    bits = if family == 4, do: 32, else: 128
    # A v4-mapped address (::ffff:a.b.c.d) is matched as IPv4: drop its 96-bit prefix.
    mapped = if family == 4 and tuple_size(ip) == 8, do: 96, else: 0
    prefix = (String.to_integer(len) - mapped) |> max(0) |> min(bits)
    mask = bxor((1 <<< bits) - 1, (1 <<< (bits - prefix)) - 1)
    {family, value &&& mask, mask}
  end

  defp normalize({0, 0, 0, 0, 0, 0xFFFF, hi, lo}), do: {4, hi <<< 16 ||| lo}
  defp normalize({a, b, c, d}), do: {4, a <<< 24 ||| b <<< 16 ||| c <<< 8 ||| d}

  defp normalize(ip) when tuple_size(ip) == 8,
    do: {6, ip |> Tuple.to_list() |> Enum.reduce(0, fn w, acc -> acc <<< 16 ||| w end)}
end
