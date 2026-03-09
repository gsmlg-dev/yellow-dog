defmodule YellowDog.Resolved.RouterTest do
  use ExUnit.Case, async: false

  alias YellowDog.Resolved.{Cache, Config, Router}

  @test_config %{
    listen: {127, 0, 0, 1},
    port: 15353,
    upstreams: [{127, 0, 0, 1}],
    upstream_timeout_ms: 1000,
    upstream_failure_threshold: 3,
    cache: %{
      enabled: true,
      max_entries: 1000,
      min_ttl_s: 5,
      max_ttl_s: 3600,
      negative_ttl_s: 30,
      sweep_interval_s: 3600
    },
    discovery: %{enabled: false, websocket: %{}},
    intercept_rules: [
      %{match: {:exact, "myapp.test"}, type: :a, value: "192.168.1.100", ttl: 600},
      %{match: {:suffix, "local.dev"}, type: :a, value: "127.0.0.1", ttl: 300}
    ]
  }

  setup do
    start_supervised!({Config, @test_config})
    start_supervised!({Cache, @test_config.cache})
    :ok
  end

  defp build_query(domain, type \\ :a) do
    query = DNS.Message.new()
    question = DNS.Message.Question.new(domain, type, :in)

    %{
      query
      | header: %{query.header | id: :rand.uniform(65_535), rd: 1, qdcount: 1},
        qdlist: [question]
    }
  end

  describe "resolve/1 with intercept" do
    test "intercepts exact match domain" do
      query = build_query("myapp.test")
      response = Router.resolve(query)

      assert response.header.qr == 1
      assert response.header.aa == 1
      assert response.header.id == query.header.id
      assert length(response.anlist) == 1
    end

    test "intercepts suffix match domain" do
      query = build_query("app.local.dev")
      response = Router.resolve(query)

      assert response.header.qr == 1
      assert length(response.anlist) == 1
    end

    test "returns empty answer when query type doesn't match rule type" do
      query = build_query("myapp.test", :aaaa)
      response = Router.resolve(query)

      assert response.header.qr == 1
      assert response.header.rcode == DNS.Message.RCode.no_error()
      assert response.anlist == []
    end
  end
end
