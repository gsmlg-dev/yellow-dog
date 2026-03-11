defmodule YellowDog.Resolved.InterceptTest do
  use ExUnit.Case, async: true

  alias YellowDog.Resolved.Intercept

  @rules [
    %{match: {:exact, "myapp.test"}, type: :a, value: "192.168.1.100", ttl: 600},
    %{match: {:suffix, "local.dev"}, type: :a, value: "127.0.0.1", ttl: 300},
    %{match: {:prefix, "dev-"}, type: :a, value: "10.0.0.1", ttl: 300},
    %{match: {:suffix, "local.dev"}, type: :aaaa, value: "::1", ttl: 300}
  ]

  describe "match/3" do
    test "matches exact domain with correct type" do
      assert %{type: :a, value: "192.168.1.100"} = Intercept.match("myapp.test", :a, @rules)
    end

    test "matches exact domain case-insensitively" do
      assert %{type: :a} = Intercept.match("MYAPP.TEST", :a, @rules)
      assert %{type: :a} = Intercept.match("MyApp.Test", :a, @rules)
    end

    test "matches suffix pattern" do
      assert %{type: :a, value: "127.0.0.1"} = Intercept.match("app.local.dev", :a, @rules)
      assert %{type: :a, value: "127.0.0.1"} = Intercept.match("deep.sub.local.dev", :a, @rules)
    end

    test "matches suffix pattern for exact suffix domain" do
      assert %{type: :a, value: "127.0.0.1"} = Intercept.match("local.dev", :a, @rules)
    end

    test "matches prefix pattern" do
      assert %{type: :a, value: "10.0.0.1"} = Intercept.match("dev-server.example.com", :a, @rules)
    end

    test "returns nil for non-matching domain" do
      assert nil == Intercept.match("google.com", :a, @rules)
    end

    test "returns nil when domain matches but type does not" do
      # @rules has no CNAME rule — A-rule for myapp.test must not block CNAME queries
      assert nil == Intercept.match("myapp.test", :cname, @rules)
    end

    test "A and AAAA rules for same domain are independently reachable" do
      # Without type-aware matching, the AAAA rule would be shadowed by the A rule
      assert %{type: :a, value: "127.0.0.1"} = Intercept.match("app.local.dev", :a, @rules)
      assert %{type: :aaaa, value: "::1"} = Intercept.match("app.local.dev", :aaaa, @rules)
    end

    test "first match by type wins" do
      rules = [
        %{match: {:suffix, "example.com"}, type: :a, value: "1.1.1.1", ttl: 300},
        %{match: {:exact, "test.example.com"}, type: :a, value: "2.2.2.2", ttl: 300}
      ]

      assert %{value: "1.1.1.1"} = Intercept.match("test.example.com", :a, rules)
    end

    test "handles trailing dot in domain" do
      assert %{type: :a} = Intercept.match("myapp.test.", :a, @rules)
    end

    test "returns nil for empty rules" do
      assert nil == Intercept.match("anything.com", :a, [])
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
