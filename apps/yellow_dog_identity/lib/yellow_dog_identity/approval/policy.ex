defmodule YellowDogIdentity.Approval.Policy do
  @moduledoc """
  Approval policy struct and TOML parsing.

  Policies are evaluated in order by the engine; first match wins.
  """

  @type action :: :approve | :reject | :pending

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          match: map(),
          action: action()
        }

  @enforce_keys [:name, :action]
  defstruct [
    :name,
    :description,
    match: %{},
    action: :pending
  ]

  @valid_actions ~w(approve reject pending)

  @doc """
  Parses a list of policy maps from TOML config into Policy structs.
  """
  @spec from_config(list()) :: [t()]
  def from_config(policy_list) when is_list(policy_list) do
    Enum.map(policy_list, &parse_policy/1)
  end

  def from_config(_), do: []

  @doc """
  Checks if a policy matches the given registration context.
  """
  @spec matches?(t(), map()) :: boolean()
  def matches?(%__MODULE__{match: match}, context) do
    Enum.all?(match, fn {field, expected} ->
      actual = Map.get(context, field) || Map.get(context, to_string(field))
      field_matches?(actual, expected)
    end)
  end

  defp parse_policy(map) when is_map(map) do
    %__MODULE__{
      name: Map.get(map, "name", "unnamed"),
      description: Map.get(map, "description"),
      match: parse_match(Map.get(map, "match", %{})),
      action: parse_action(Map.get(map, "action", "pending"))
    }
  end

  defp parse_match(match) when is_map(match) do
    Map.new(match, fn {key, value} -> {key, value} end)
  end

  defp parse_match(_), do: %{}

  defp parse_action(action) when action in @valid_actions, do: String.to_existing_atom(action)
  defp parse_action(_), do: :pending

  defp field_matches?(_actual, nil), do: true
  defp field_matches?(nil, _expected), do: false

  # List match: actual must be in the expected list
  defp field_matches?(actual, expected) when is_list(expected) do
    to_string(actual) in Enum.map(expected, &to_string/1)
  end

  # Glob pattern match for hostname patterns
  defp field_matches?(actual, expected) when is_binary(expected) and is_binary(actual) do
    if String.contains?(expected, "*") do
      glob_match?(actual, expected)
    else
      to_string(actual) == expected
    end
  end

  # Exact match
  defp field_matches?(actual, expected), do: to_string(actual) == to_string(expected)

  # Safe glob matching without regex to prevent ReDoS.
  # Splits pattern on "*" and verifies segments appear in order.
  defp glob_match?(string, pattern) do
    parts = String.split(pattern, "*", parts: :infinity)

    case parts do
      [exact] ->
        string == exact

      [prefix | rest] ->
        String.starts_with?(string, prefix) &&
          glob_match_rest(String.slice(string, String.length(prefix)..-1//1), rest)
    end
  end

  defp glob_match_rest(_string, []), do: true

  # Skip empty segments from consecutive wildcards (**)
  defp glob_match_rest(string, ["" | rest]), do: glob_match_rest(string, rest)

  defp glob_match_rest(string, [last]) do
    String.ends_with?(string, last)
  end

  defp glob_match_rest(string, [segment | rest]) do
    case :binary.match(string, segment) do
      {pos, len} ->
        glob_match_rest(String.slice(string, (pos + len)..-1//1), rest)

      :nomatch ->
        false
    end
  end
end
