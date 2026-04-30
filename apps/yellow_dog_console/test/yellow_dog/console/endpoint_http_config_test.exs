defmodule YellowDog.Console.EndpointHttpConfigTest do
  use ExUnit.Case, async: true

  @max_acceptors 8
  @max_connections 128

  test "development HTTP listener uses bounded local Bandit capacity" do
    assert_http_capacity("dev.exs")
  end

  test "test HTTP listener uses bounded local Bandit capacity" do
    assert_http_capacity("test.exs")
  end

  defp assert_http_capacity(config_path) do
    http_options = endpoint_http_options(config_path)
    thousand_island_options = Keyword.fetch!(http_options, :thousand_island_options)

    assert Keyword.fetch!(thousand_island_options, :num_acceptors) <= @max_acceptors
    assert Keyword.fetch!(thousand_island_options, :num_connections) <= @max_connections
  end

  defp endpoint_http_options(config_file) do
    config_path(config_file)
    |> Config.Reader.read!(env: :test)
    |> get_in([:yellow_dog_console, YellowDog.Console.Endpoint, :http])
  end

  defp config_path(config_file) do
    Path.expand("../../../../../config/#{config_file}", __DIR__)
  end
end
