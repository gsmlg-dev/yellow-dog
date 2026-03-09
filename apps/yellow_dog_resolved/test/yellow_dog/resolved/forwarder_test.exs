defmodule YellowDog.Resolved.ForwarderTest do
  use ExUnit.Case, async: false

  alias YellowDog.Resolved.Forwarder

  # Forwarder tests require network access or mocks.
  # Basic unit tests for internal logic.

  describe "forwarder initialization" do
    test "starts with configured upstreams" do
      config = %{
        upstreams: [{8, 8, 8, 8}, {1, 1, 1, 1}],
        upstream_timeout_ms: 1000,
        upstream_failure_threshold: 3
      }

      assert {:ok, pid} = Forwarder.start_link(config)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end
end
