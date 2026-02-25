defmodule YellowDog.Resolved.RouterTest do
  use ExUnit.Case, async: false

  alias YellowDog.Resolved.{Cache, Config, Router}

  @cache_config %{
    enabled: true,
    max_entries: 1000,
    min_ttl_s: 5,
    max_ttl_s: 3600,
    negative_ttl_s: 60,
    sweep_interval_s: 3600
  }

  @config %{
    listen: {127, 0, 0, 1},
    port: 0,
    upstreams: [{198, 51, 100, 1}],
    upstream_timeout_ms: 200,
    upstream_failure_threshold: 3,
    intercept_rules: [
      %{match: {:suffix, "local.dev"}, type: :a, value: "127.0.0.1", ttl: 300},
      %{match: {:exact, "myapp.test"}, type: :a, value: "192.168.1.100", ttl: 600}
    ],
    cache: @cache_config,
    discovery: %{
      enabled: false,
      websocket: %{heartbeat_interval_s: 30, reconnect_base_s: 5, reconnect_max_s: 60}
    },
    config_path: ""
  }

  setup do
    start_supervised!({Config, @config})
    start_supervised!({Cache, @cache_config})
    :ok
  end

  defp build_query(domain, type_num) do
    query = DNS.Message.new()
    query = DNS.Message.update_header_attr(query, :id, :rand.uniform(65535))
    query = DNS.Message.update_header_attr(query, :rd, 1)
    DNS.Message.add_question(query, DNS.Message.Question.new(domain, type_num, 1))
  end

  describe "resolve with intercept" do
    test "returns intercepted response for matching domain" do
      query = build_query("app.local.dev", 1)
      raw = DNS.to_iodata(query) |> IO.iodata_to_binary()

      assert {:ok, response_binary, :intercept} = Router.resolve(query, raw)
      assert is_binary(response_binary)

      # Decode and verify
      response = DNS.Message.from_iodata(response_binary)
      assert response.header.qr == 1
      assert response.header.aa == 1
      assert length(response.anlist) == 1
    end

    test "returns empty answer for mismatched type" do
      # Query AAAA for a domain that only has A rule
      query = build_query("myapp.test", 28)
      raw = DNS.to_iodata(query) |> IO.iodata_to_binary()

      assert {:ok, response_binary, :intercept} = Router.resolve(query, raw)

      response = DNS.Message.from_iodata(response_binary)
      assert response.header.qr == 1
      assert response.anlist == []
    end

    test "intercept preserves query transaction ID" do
      query = build_query("app.local.dev", 1)
      raw = DNS.to_iodata(query) |> IO.iodata_to_binary()

      assert {:ok, response_binary, :intercept} = Router.resolve(query, raw)
      response = DNS.Message.from_iodata(response_binary)

      assert response.header.id == query.header.id
    end

    test "intercept for exact match" do
      query = build_query("myapp.test", 1)
      raw = DNS.to_iodata(query) |> IO.iodata_to_binary()

      assert {:ok, response_binary, :intercept} = Router.resolve(query, raw)
      response = DNS.Message.from_iodata(response_binary)

      assert length(response.anlist) == 1
      [record] = response.anlist
      assert record.ttl == 600
    end
  end

  describe "resolve with cache" do
    test "cache hit returns cached response" do
      # Pre-populate cache with a fake response
      query = build_query("cached.example.com", 1)
      raw = DNS.to_iodata(query) |> IO.iodata_to_binary()

      # Build a fake response binary
      response = DNS.Message.new()
      response = DNS.Message.update_header_attr(response, :id, 9999)
      response = DNS.Message.update_header_attr(response, :qr, 1)
      response = DNS.Message.update_header_attr(response, :rd, 1)
      response_binary = DNS.to_iodata(response) |> IO.iodata_to_binary()

      Cache.store("cached.example.com", :a, response_binary, 300)
      Process.sleep(10)

      assert {:ok, result_binary, :cache} = Router.resolve(query, raw)
      assert is_binary(result_binary)

      # Transaction ID should be rewritten to match query
      <<txn_id::16, _rest::binary>> = result_binary
      assert txn_id == query.header.id
    end
  end

  describe "resolve with empty query" do
    test "returns FORMERR for query without questions" do
      query = DNS.Message.new()
      query = DNS.Message.update_header_attr(query, :id, 1234)
      raw = DNS.to_iodata(query) |> IO.iodata_to_binary()

      assert {:ok, response_binary} = Router.resolve(query, raw)
      assert is_binary(response_binary)
    end
  end

  describe "resolve non-intercepted domain (forward path)" do
    test "returns SERVFAIL when forwarder not started" do
      # No forwarder is started in this test setup — GenServer.call exit
      # Router should catch the exit and return SERVFAIL
      query = build_query("external.com", 1)
      raw = DNS.to_iodata(query) |> IO.iodata_to_binary()

      assert {:ok, response_binary} = Router.resolve(query, raw)
      assert is_binary(response_binary)

      # Verify it's a valid DNS response
      response = DNS.Message.from_iodata(response_binary)
      assert response.header.qr == 1
    end
  end
end
