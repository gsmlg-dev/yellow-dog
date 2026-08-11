defmodule YellowDog.NetmanAgent.BootstrapTest do
  use ExUnit.Case, async: true

  alias YellowDog.NetmanAgent.Bootstrap

  @valid [
    management_url: "https://management.example.test:4443",
    management_token: "local-secret",
    netman_id: "netman-east-1",
    data_dir: "/var/lib/yellow-dog/netman-agent"
  ]

  test "accepts one complete local bootstrap and supplies bounded reconnect defaults" do
    assert {:ok,
            %{
              management_url: "https://management.example.test:4443",
              management_token: "local-secret",
              netman_id: "netman-east-1",
              data_dir: "/var/lib/yellow-dog/netman-agent",
              reconnect_initial_ms: 1_000,
              reconnect_max_ms: 30_000
            }} = Bootstrap.validate(@valid)

    assert {:ok, %{reconnect_initial_ms: 250, reconnect_max_ms: 5_000}} =
             Bootstrap.validate(@valid ++ [reconnect_initial_ms: 250, reconnect_max_ms: 5_000])
  end

  test "rejects partial, remote-shaped, and unsafe local bootstrap values" do
    invalid = [
      Keyword.delete(@valid, :management_token),
      Keyword.put(@valid, :management_token, ""),
      Keyword.put(@valid, :management_url, "http://management.example.test:4443"),
      Keyword.put(@valid, :management_url, "https://management.example.test"),
      Keyword.put(@valid, :management_url, "https://user@management.example.test:4443"),
      Keyword.put(@valid, :netman_id, "../netman"),
      Keyword.put(@valid, :data_dir, "relative/agent"),
      @valid ++ [reconnect_initial_ms: 5_000, reconnect_max_ms: 250],
      @valid ++ [unknown: "remote-config"]
    ]

    assert Enum.all?(invalid, &(Bootstrap.validate(&1) == :error))
  end
end
