defmodule YellowDog.Resolved.Intercept do
  @moduledoc """
  Rule matching engine for DNS query interception.
  Evaluates rules in order; first match wins.
  """

  @type match_pattern ::
          {:exact, String.t()}
          | {:suffix, String.t()}
          | {:prefix, String.t()}

  @type rule :: %{
          match: match_pattern(),
          type: atom(),
          value: binary(),
          ttl: pos_integer()
        }

  # Maps DNS.ResourceRecordType string representation to rule type atoms
  @type_string_map %{
    "A" => :a,
    "AAAA" => :aaaa,
    "CNAME" => :cname,
    "TXT" => :txt,
    "MX" => :mx,
    "SRV" => :srv,
    "NS" => :ns,
    "PTR" => :ptr,
    "SOA" => :soa
  }

  @doc """
  Check if a domain and query type match any intercept rule.
  Returns the first rule whose domain pattern AND record type match, or nil.

  Both domain pattern and type must match so that an AAAA rule and an A rule
  for the same domain can coexist: querying AAAA skips A-only rules and finds
  the AAAA rule rather than silently returning NODATA.

  Accepts the type as either an atom (`:a`) or a `DNS.ResourceRecordType` struct.
  """
  @spec match(String.t(), atom() | term(), [rule()]) :: rule() | nil
  def match(domain, type, rules) do
    normalized = String.downcase(domain) |> String.trim_trailing(".")
    type_atom = normalize_type(type)
    Enum.find(rules, fn rule -> rule.type == type_atom and matches?(normalized, rule.match) end)
  end

  @doc """
  Check if a domain matches a specific pattern.
  """
  @spec matches?(String.t(), match_pattern()) :: boolean()
  def matches?(domain, {:exact, pattern}) do
    String.downcase(domain) == String.downcase(pattern)
  end

  def matches?(domain, {:suffix, suffix}) do
    normalized_suffix = String.downcase(suffix)
    normalized_domain = String.downcase(domain)

    normalized_domain == normalized_suffix or
      String.ends_with?(normalized_domain, "." <> normalized_suffix)
  end

  def matches?(domain, {:prefix, prefix}) do
    String.starts_with?(String.downcase(domain), String.downcase(prefix))
  end

  defp normalize_type(type) when is_atom(type), do: type

  defp normalize_type(type) do
    Map.get(@type_string_map, to_string(type), :unknown)
  end
end
