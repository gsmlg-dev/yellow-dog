defmodule YellowDog.Console.EndpointHttpConfigTest do
  use ExUnit.Case, async: true

  @max_active 128

  test "development HTTP listener uses bounded local Gaoxy capacity" do
    assert_http_capacity("dev.exs")
  end

  test "test HTTP listener uses bounded local Gaoxy capacity" do
    assert_http_capacity("test.exs")
  end

  defp assert_http_capacity(config_path) do
    endpoint_options = endpoint_options(config_path)
    http_options = Keyword.fetch!(endpoint_options, :http)
    limits = Keyword.fetch!(http_options, :limits)

    assert Keyword.fetch!(endpoint_options, :adapter) == Gaoxy.PhoenixAdapter

    assert Keyword.fetch!(endpoint_options, :websocket_paths) == [
             "/live/websocket",
             "/netman/ws/websocket",
             "/server/ws/websocket"
           ]

    assert limits.max_active in 1..@max_active
  end

  defp endpoint_options(config_file) do
    config_path(config_file)
    |> Config.Reader.read!(env: :test)
    |> get_in([:yellow_dog_console, YellowDog.Console.Endpoint])
  end

  defp config_path(config_file) do
    Path.expand("../../../../../config/#{config_file}", __DIR__)
  end
end
