defmodule YellowDog.ManagementUI.DnsRulesText do
  @moduledoc "One ordered-rule editor grammar for named ACLs and View client policies."

  alias YellowDog.Management.Countries

  @max_bytes 262_144

  def parse(text) when is_binary(text) and byte_size(text) <= @max_bytes do
    lines = text |> String.split("\n") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

    if length(lines) > 128 do
      {:error, {:rules, "At most 128 ordered rules are allowed"}}
    else
      result =
        Enum.reduce_while(Enum.with_index(lines, 1), {:ok, []}, fn {line, index}, {:ok, rules} ->
          case parse_rule(line) do
            {:ok, rule} -> {:cont, {:ok, [rule | rules]}}
            {:error, error} -> {:halt, {:error, {:rules, "Line #{index}: #{error}"}}}
          end
        end)

      with {:ok, rules} <- result,
           true <-
             Enum.reduce(rules, 0, fn rule, total -> total + length(rule["networks"] || []) end) <=
               128 do
        {:ok, Enum.reverse(rules)}
      else
        false -> {:error, {:rules, "At most 128 networks across all rules are allowed"}}
        {:error, error} -> {:error, error}
      end
    end
  end

  def parse(_text), do: {:error, {:rules, "Rules text must be at most 256 KiB"}}

  defp parse_rule(line) do
    case String.split(line, ~r/\s+/, parts: 3) do
      [action, "any"] when action in ~w(allow deny) ->
        {:ok, %{"action" => action, "kind" => "any"}}

      [action, "networks"] when action in ~w(allow deny) ->
        {:ok, %{"action" => action, "kind" => "networks", "networks" => []}}

      [action, "networks", values] when action in ~w(allow deny) ->
        networks = split_values(values)

        if Enum.all?(networks, &valid_network?/1),
          do: {:ok, %{"action" => action, "kind" => "networks", "networks" => networks}},
          else: {:error, "Networks must contain valid IP addresses or CIDRs"}

      [action, "countries", values] when action in ~w(allow deny) ->
        countries = split_values(values)

        if length(countries) <= 249 and
             Enum.all?(countries, &(Regex.match?(~r/\A[A-Z]{2}\z/, &1) and Countries.valid?(&1))),
           do:
             {:ok,
              %{
                "action" => action,
                "kind" => "countries",
                "countries" => countries |> Enum.uniq() |> Enum.sort()
              }},
           else:
             {:error,
              "Countries must be nonempty uppercase ISO codes from the catalog, at most 249"}

      _ ->
        {:error, "Use allow|deny any, networks IP_OR_CIDR[, ...], or countries ISO[, ...]"}
    end
  end

  defp split_values(values), do: values |> String.split(",") |> Enum.map(&String.trim/1)

  defp valid_network?(value) do
    case String.split(value, "/") do
      [address] ->
        match?({:ok, _tuple}, :inet.parse_strict_address(String.to_charlist(address)))

      [address, prefix] ->
        with {:ok, tuple} <- :inet.parse_strict_address(String.to_charlist(address)),
             true <- Regex.match?(~r/\A[0-9]{1,3}\z/, prefix),
             {number, ""} <- Integer.parse(prefix) do
          number <= if(tuple_size(tuple) == 4, do: 32, else: 128)
        else
          _ -> false
        end

      _ ->
        false
    end
  end

  def format(rules), do: Enum.map_join(rules, "\n", &format_rule/1)

  defp format_rule(%{"action" => action, "kind" => "any"}), do: action <> " any"

  defp format_rule(%{"action" => action, "kind" => "networks", "networks" => networks}),
    do: String.trim_trailing(action <> " networks " <> Enum.join(networks, ", "))

  defp format_rule(%{"action" => action, "kind" => "countries", "countries" => countries}),
    do: action <> " countries " <> Enum.join(countries, ", ")
end
