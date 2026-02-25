defmodule YellowDog.Resolved.Intercept do
  @moduledoc """
  DNS intercept rule matching engine.

  Evaluates incoming queries against configured intercept rules.
  Rules are evaluated in order; first match wins. Matching is case-insensitive.

  Supported match patterns:
  - `{:exact, "myapp.local.dev"}` — exact domain match
  - `{:suffix, "local.dev"}` — matches anything ending in `.local.dev`
  - `{:prefix, "dev-"}` — matches anything starting with `dev-`
  """

  alias YellowDog.Resolved.Config

  @type match_result :: {:match, Config.intercept_rule()} | :no_match

  @doc """
  Find the first matching intercept rule for the given domain and query type.
  Returns `{:match, rule}` if a rule matches, `:no_match` otherwise.
  """
  @spec match(String.t(), atom(), [Config.intercept_rule()]) :: match_result()
  def match(domain, _query_type, rules) do
    normalized = String.downcase(domain) |> String.trim_trailing(".")

    # First domain-pattern match wins. Type filtering happens in ResponseBuilder:
    # matching type → answer with record; mismatched type → NOERROR, 0 answers.
    Enum.find_value(rules, :no_match, fn rule ->
      if matches_pattern?(normalized, rule.match) do
        {:match, rule}
      end
    end)
  end

  @doc """
  Check if a domain matches a single pattern. Exported for testing.
  """
  @spec matches_pattern?(String.t(), {:exact | :suffix | :prefix, String.t()}) :: boolean()
  def matches_pattern?(domain, {:exact, pattern}) do
    domain == pattern
  end

  def matches_pattern?(domain, {:suffix, pattern}) do
    domain == pattern or String.ends_with?(domain, "." <> pattern)
  end

  def matches_pattern?(domain, {:prefix, pattern}) do
    String.starts_with?(domain, pattern)
  end
end
