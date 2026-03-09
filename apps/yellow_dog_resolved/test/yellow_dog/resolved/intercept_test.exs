defmodule YellowDog.Resolved.InterceptTest do
  use ExUnit.Case, async: true

  alias YellowDog.Resolved.Intercept

  @rules [
    %{match: {:exact, "myapp.test"}, type: :a, value: "192.168.1.100", ttl: 600},
    %{match: {:suffix, "local.dev"}, type: :a, value: "127.0.0.1", ttl: 300},
    %{match: {:prefix, "dev-"}, type: :a, value: "10.0.0.1", ttl: 300},
    %{match: {:suffix, "local.dev"}, type: :aaaa, value: "::1", ttl: 300}
  ]

  describe "match/2" do
    test "matches exact domain" do
      assert %{type: :a, value: "192.168.1.100"} = Intercept.match("myapp.test", @rules)
    end

    test "matches exact domain case-insensitively" do
      assert %{type: :a} = Intercept.match("MYAPP.TEST", @rules)
      assert %{type: :a} = Intercept.match("MyApp.Test", @rules)
    end

    test "matches suffix pattern" do
      assert %{type: :a, value: "127.0.0.1"} = Intercept.match("app.local.dev", @rules)
      assert %{type: :a, value: "127.0.0.1"} = Intercept.match("deep.sub.local.dev", @rules)
    end

    test "matches suffix pattern for exact suffix domain" do
      assert %{type: :a, value: "127.0.0.1"} = Intercept.match("local.dev", @rules)
    end

    test "matches prefix pattern" do
      assert %{type: :a, value: "10.0.0.1"} = Intercept.match("dev-server.example.com", @rules)
    end

    test "returns nil for non-matching domain" do
      assert nil == Intercept.match("google.com", @rules)
    end

    test "first match wins" do
      rules = [
        %{match: {:suffix, "example.com"}, type: :a, value: "1.1.1.1", ttl: 300},
        %{match: {:exact, "test.example.com"}, type: :a, value: "2.2.2.2", ttl: 300}
      ]

      # Suffix matches first
      assert %{value: "1.1.1.1"} = Intercept.match("test.example.com", rules)
    end

    test "handles trailing dot in domain" do
      assert %{type: :a} = Intercept.match("myapp.test.", @rules)
    end

    test "returns nil for empty rules" do
      assert nil == Intercept.match("anything.com", [])
    end
  end

  describe "matches?/2" do
    test "exact match is case-insensitive" do
      assert Intercept.matches?("FOO.BAR", {:exact, "foo.bar"})
      refute Intercept.matches?("foo.baz", {:exact, "foo.bar"})
    end

    test "suffix match" do
      assert Intercept.matches?("sub.example.com", {:suffix, "example.com"})
      refute Intercept.matches?("notexample.com", {:suffix, "example.com"})
    end

    test "prefix match" do
      assert Intercept.matches?("dev-server", {:prefix, "dev-"})
      refute Intercept.matches?("prod-server", {:prefix, "dev-"})
    end
  end
end
