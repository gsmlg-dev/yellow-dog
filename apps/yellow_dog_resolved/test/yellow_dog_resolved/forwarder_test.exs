defmodule YellowDog.Resolved.ForwarderTest do
  use ExUnit.Case, async: false

  alias YellowDog.Resolved.Forwarder

  @config %{
    upstreams: [{127, 0, 0, 1}],
    upstream_timeout_ms: 1000,
    upstream_failure_threshold: 3
  }

  describe "start_link/1" do
    test "starts the forwarder" do
      assert {:ok, pid} =
               start_supervised({Forwarder, @config})

      assert Process.alive?(pid)
    end
  end

  describe "forward/1 with unreachable upstream" do
    setup do
      # Use a non-routable IP to force timeout
      config = %{@config | upstreams: [{198, 51, 100, 1}], upstream_timeout_ms: 200}
      start_supervised!({Forwarder, config})
      :ok
    end

    test "returns error when all upstreams fail" do
      query = DNS.Message.new()
      query = DNS.Message.update_header_attr(query, :id, 1234)
      query = DNS.Message.update_header_attr(query, :rd, 1)
      query = DNS.Message.add_question(query, DNS.Message.Question.new("example.com", 1, 1))

      assert {:error, :all_upstreams_failed} = Forwarder.forward(query)
    end
  end
end
