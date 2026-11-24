defmodule YellowDog.Worker.Dns.Views do
  @moduledoc false
  alias YellowDog.Worker.Dns.Acl

  def compile(views) when is_list(views) do
    Enum.reduce_while(views, {:ok, []}, fn
      %{"id" => id, "recursion_enabled" => recursion, "client_rules" => rules} = view, {:ok, acc}
      when is_binary(id) and is_boolean(recursion) and is_list(rules) ->
        with {:ok, rules} <- compile_rules(rules) do
          priority = if is_map_key(view, "priority"), do: {0, view["priority"]}, else: {1, 0}
          {:cont, {:ok, [{priority, id, recursion, rules} | acc]}}
        else
          error -> {:halt, error}
        end

      _view, _acc ->
        {:halt, {:error, :invalid_dns_views}}
    end)
    |> case do
      {:ok, compiled} -> {:ok, Enum.sort(compiled)}
      error -> error
    end
  end

  def compile(_views), do: {:error, :invalid_dns_views}

  def select(views, ip) do
    Enum.find_value(views, fn {_priority, id, recursion, rules} ->
      if first_match(rules, ip) == "allow", do: %{scope: {:view, id}, recursion: recursion}
    end)
  end

  defp first_match(rules, ip) do
    Enum.find_value(rules, fn
      {action, :any} -> action
      {action, acl} -> if Acl.allowed?(acl, ip), do: action
    end)
  end

  defp compile_rules(rules) do
    Enum.reduce_while(rules, {:ok, []}, fn
      %{"action" => action, "kind" => "any"}, {:ok, acc} when action in ~w(allow deny) ->
        {:cont, {:ok, [{action, :any} | acc]}}

      %{"action" => action, "kind" => "networks", "networks" => networks}, {:ok, acc}
      when action in ~w(allow deny) and is_list(networks) ->
        {:ok, acl} = Acl.compile(networks)
        {:cont, {:ok, [{action, acl} | acc]}}

      _rule, _acc ->
        {:halt, {:error, :invalid_view_client_rules}}
    end)
    |> case do
      {:ok, compiled} -> {:ok, Enum.reverse(compiled)}
      error -> error
    end
  rescue
    _ -> {:error, :invalid_view_client_rules}
  end
end
