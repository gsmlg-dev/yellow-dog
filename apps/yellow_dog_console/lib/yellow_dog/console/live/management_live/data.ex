defmodule YellowDog.Console.ManagementLive.Data do
  @moduledoc false

  @facade YellowDog.ManagementCore

  def list_servers, do: facade_list(:list_servers)
  def list_netmans, do: facade_list(:list_netmans)
  def list_server_profiles, do: facade_list(:list_server_profiles)
  def list_netman_profiles, do: facade_list(:list_netman_profiles)
  def list_events, do: facade_list(:list_events)

  defp facade_list(function) do
    if Code.ensure_loaded?(@facade) and function_exported?(@facade, function, 0) do
      case apply(@facade, function, []) do
        values when is_list(values) -> values
        {:ok, values} when is_list(values) -> values
        _other -> []
      end
    else
      []
    end
  end
end
