defmodule YellowDog.Resolved.InterceptTest do
  use ExUnit.Case, async: true

  alias YellowDog.Resolved.Intercept

  @rules [
    %{match: {:suffix, "local.dev"}, type: :a, value: "127.0.0.1", ttl: 300},
    %{match: {:suffix, "local.dev"}, type: :aaaa, value: "::1", ttl: 300},
    %{match: {:exact, "myapp.test"}, type: :a, value: "192.168.1.100", ttl: 600},
    %{match: {:prefix, "dev-"}, type: :a, value: "10.0.0.1", ttl: 120},
    %{match: {:exact, "db.internal"}, type: :cname, value: "postgres.local.dev", ttl: 300}
  ]

  describe "exact matching" do
    test "matches exact domain" do
      assert {:match, rule} = Intercept.match("myapp.test", :a, @rules)
      assert rule.value == "192.168.1.100"
    end

    test "does not match partial domain" do
      assert :no_match = Intercept.match("notmyapp.test", :a, @rules)
    end

    test "case insensitive" do
      assert {:match, _rule} = Intercept.match("MyApp.Test", :a, @rules)
    end

    test "strips trailing dot" do
      assert {:match, _rule} = Intercept.match("myapp.test.", :a, @rules)
    end
  end

  describe "suffix matching" do
    test "matches subdomain of suffix" do
      assert {:match, rule} = Intercept.match("app.local.dev", :a, @rules)
      assert rule.value == "127.0.0.1"
    end

    test "matches deep subdomain" do
      assert {:match, _rule} = Intercept.match("deep.sub.local.dev", :a, @rules)
    end

    test "matches exact suffix domain" do
      assert {:match, _rule} = Intercept.match("local.dev", :a, @rules)
    end

    test "does not match non-suffix" do
      assert :no_match = Intercept.match("localdev.com", :a, @rules)
    end

    test "does not match with different ending" do
      assert :no_match = Intercept.match("notlocal.dev.com", :a, @rules)
    end
  end

  describe "prefix matching" do
    test "matches prefix" do
      assert {:match, rule} = Intercept.match("dev-server", :a, @rules)
      assert rule.value == "10.0.0.1"
    end

    test "matches prefix with dots" do
      assert {:match, _rule} = Intercept.match("dev-app.example.com", :a, @rules)
    end

    test "does not match non-prefix" do
      assert :no_match = Intercept.match("mydev-server", :a, @rules)
    end
  end

  describe "first match wins" do
    test "suffix rule matches before exact for overlapping domain" do
      # "app.local.dev" matches suffix rule first
      assert {:match, rule} = Intercept.match("app.local.dev", :a, @rules)
      assert rule.type == :a
      assert rule.value == "127.0.0.1"
    end

    test "first type variant wins for same domain pattern" do
      # Both :a and :aaaa suffix rules exist, :a is first
      assert {:match, rule} = Intercept.match("app.local.dev", :aaaa, @rules)
      # Still matches first rule (type matching is independent)
      assert rule.type == :a
    end
  end

  describe "matches_pattern?/2" do
    test "exact pattern" do
      assert Intercept.matches_pattern?("example.com", {:exact, "example.com"})
      refute Intercept.matches_pattern?("sub.example.com", {:exact, "example.com"})
    end

    test "suffix pattern" do
      assert Intercept.matches_pattern?("sub.example.com", {:suffix, "example.com"})
      assert Intercept.matches_pattern?("example.com", {:suffix, "example.com"})
      refute Intercept.matches_pattern?("notexample.com", {:suffix, "example.com"})
    end

    test "prefix pattern" do
      assert Intercept.matches_pattern?("dev-server", {:prefix, "dev-"})
      refute Intercept.matches_pattern?("server-dev", {:prefix, "dev-"})
    end
  end

  describe "empty rules" do
    test "no rules always returns :no_match" do
      assert :no_match = Intercept.match("anything.com", :a, [])
    end
  end
end
