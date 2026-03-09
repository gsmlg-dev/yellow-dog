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

  @doc """
  Check if a domain matches any intercept rule.
  Returns the first matching rule or nil.
  """
  @spec match(String.t(), [rule()]) :: rule() | nil
  def match(domain, rules) do
    normalized = String.downcase(domain) |> String.trim_trailing(".")
    Enum.find(rules, fn rule -> matches?(normalized, rule.match) end)
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
end
