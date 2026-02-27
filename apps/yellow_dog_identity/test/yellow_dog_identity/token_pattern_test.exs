defmodule YellowDogIdentity.TokenPatternTest do
  @moduledoc """
  Tests for `YellowDogIdentity.Token.hostname_matches?/2` pattern matching.
  """

  use ExUnit.Case, async: true

  alias YellowDogIdentity.Token

  describe "hostname_matches?/2" do
    test "wildcard * matches any hostname" do
      assert Token.hostname_matches?("node-01", "*")
      assert Token.hostname_matches?("anything-at-all", "*")
      assert Token.hostname_matches?("", "*")
    end

    test "exact match works" do
      assert Token.hostname_matches?("node-01", "node-01")
    end

    test "exact match fails on different hostname" do
      refute Token.hostname_matches?("node-01", "node-02")
    end

    test "prefix wildcard: node-* matches node-prefixed hostnames" do
      assert Token.hostname_matches?("node-01", "node-*")
      assert Token.hostname_matches?("node-abc", "node-*")
      refute Token.hostname_matches?("server-01", "node-*")
    end

    test "suffix wildcard: *-worker matches worker-suffixed hostnames" do
      assert Token.hostname_matches?("web-worker", "*-worker")
      assert Token.hostname_matches?("api-worker", "*-worker")
      refute Token.hostname_matches?("worker-node", "*-worker")
    end

    test "middle wildcard: web-*-prod matches hostnames with web- prefix and -prod suffix" do
      assert Token.hostname_matches?("web-server-prod", "web-*-prod")
      refute Token.hostname_matches?("web-server-staging", "web-*-prod")
    end

    test "multiple wildcards: n*-*1 matches appropriately" do
      assert Token.hostname_matches?("node-01", "n*-*1")
      refute Token.hostname_matches?("node-02", "n*-*1")
    end

    test "empty pattern does not match anything" do
      refute Token.hostname_matches?("node-01", "")
      refute Token.hostname_matches?("anything", "")
    end

    test "pattern with special regex chars is escaped and matches literally" do
      assert Token.hostname_matches?("node.01", "node.01")
      refute Token.hostname_matches?("nodeX01", "node.01")
    end

    test "ReDoS-safe: many wildcards complete in bounded time" do
      # Pattern like a*b*c*d*...*z with many wildcards would cause
      # exponential backtracking with regex. This must complete fast.
      evil_pattern = Enum.map_join(1..20, "*", fn i -> "s#{i}" end)
      long_input = String.duplicate("a", 10_000)

      # Should return false quickly without hanging
      refute Token.hostname_matches?(long_input, evil_pattern)
    end

    test "consecutive wildcards match correctly" do
      assert Token.hostname_matches?("abc", "a**c")
      assert Token.hostname_matches?("abc", "***")
    end

    test "wildcard at both ends" do
      assert Token.hostname_matches?("node-01-prod", "*-01-*")
      refute Token.hostname_matches?("node-02-prod", "*-01-*")
    end
  end
end
