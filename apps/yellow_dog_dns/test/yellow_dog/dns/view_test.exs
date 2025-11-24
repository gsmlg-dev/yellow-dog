defmodule YellowDog.Dns.ViewTest do
  use ExUnit.Case, async: true

  alias YellowDog.Dns.View
  alias YellowDog.Dns.View.ACL

  doctest YellowDog.Dns.View

  describe "default/0" do
    test "returns a view struct with default values" do
      view = View.default()

      assert %View{} = view
      assert view.name == "default"
      assert view.match_clients == :all
      assert view.zones == []
      assert view.recursion_enabled == true
    end

    test "struct has all required fields" do
      view = View.default()

      assert Map.has_key?(view, :name)
      assert Map.has_key?(view, :match_clients)
      assert Map.has_key?(view, :zones)
      assert Map.has_key?(view, :recursion_enabled)
    end
  end

  describe "match_view/1" do
    test "always returns default view for any IPv4 address" do
      assert {:ok, view} = View.match_view({192, 168, 1, 100})
      assert view.name == "default"
      assert view.match_clients == :all
    end

    test "always returns default view for any IPv6 address" do
      assert {:ok, view} = View.match_view({0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1})
      assert view.name == "default"
      assert view.match_clients == :all
    end

    test "always returns default view for localhost" do
      assert {:ok, view} = View.match_view({127, 0, 0, 1})
      assert view.name == "default"
    end

    test "always returns default view for binary IP" do
      assert {:ok, view} = View.match_view("192.168.1.1")
      assert view.name == "default"
    end

    test "returns same view instance as default/0" do
      {:ok, matched_view} = View.match_view({10, 0, 0, 1})
      default_view = View.default()

      assert matched_view.name == default_view.name
      assert matched_view.match_clients == default_view.match_clients
      assert matched_view.zones == default_view.zones
      assert matched_view.recursion_enabled == default_view.recursion_enabled
    end
  end

  describe "struct validation" do
    test "can create view with custom values" do
      view = %View{
        name: "internal",
        match_clients: [{192, 168, 0, 0}],
        zones: ["example.com"],
        recursion_enabled: false
      }

      assert view.name == "internal"
      assert view.match_clients == [{192, 168, 0, 0}]
      assert view.zones == ["example.com"]
      assert view.recursion_enabled == false
    end
  end

  describe "new/4" do
    test "creates view with all parameters" do
      view = View.new("internal", "localnets", ["corp.example.com"], true)

      assert view.name == "internal"
      assert view.match_clients == "localnets"
      assert view.zones == ["corp.example.com"]
      assert view.recursion_enabled == true
    end

    test "creates view with default zones and recursion" do
      view = View.new("internal", "localnets")

      assert view.name == "internal"
      assert view.match_clients == "localnets"
      assert view.zones == []
      assert view.recursion_enabled == true
    end

    test "creates view with :all matcher" do
      view = View.new("public", :all, ["example.com"], false)

      assert view.name == "public"
      assert view.match_clients == :all
      assert view.zones == ["example.com"]
      assert view.recursion_enabled == false
    end

    test "creates view with ACL struct" do
      acl = ACL.new("custom", [{:allow, {10, 0, 0, 0}, 8}])
      view = View.new("dmz", acl, ["dmz.example.com"], false)

      assert view.name == "dmz"
      assert view.match_clients == acl
      assert view.zones == ["dmz.example.com"]
      assert view.recursion_enabled == false
    end
  end

  describe "matches?/2" do
    test "matches :all for any IP" do
      view = View.new("public", :all)

      assert View.matches?(view, {8, 8, 8, 8})
      assert View.matches?(view, {192, 168, 1, 1})
      assert View.matches?(view, {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1})
    end

    test "matches built-in ACL by name" do
      view = View.new("internal", "localnets")

      assert View.matches?(view, {192, 168, 1, 1})
      assert View.matches?(view, {10, 0, 0, 1})
      assert View.matches?(view, {172, 16, 0, 1})
      refute View.matches?(view, {8, 8, 8, 8})
    end

    test "matches localhost ACL" do
      view = View.new("localhost", "localhost")

      assert View.matches?(view, {127, 0, 0, 1})
      assert View.matches?(view, {0, 0, 0, 0, 0, 0, 0, 1})
      refute View.matches?(view, {192, 168, 1, 1})
    end

    test "matches custom ACL struct" do
      acl = ACL.new("custom", [{:allow, {10, 0, 0, 0}, 8}])
      view = View.new("dmz", acl)

      assert View.matches?(view, {10, 1, 2, 3})
      refute View.matches?(view, {192, 168, 1, 1})
    end

    test "returns false for unknown ACL name" do
      view = View.new("test", "unknown_acl")

      refute View.matches?(view, {192, 168, 1, 1})
    end
  end

  describe "match_client/2" do
    test "returns first matching view" do
      internal = View.new("internal", "localnets", ["corp.example.com"], true)
      external = View.new("external", "any", ["public.example.com"], false)

      {:ok, matched} = View.match_client({192, 168, 1, 100}, [internal, external])
      assert matched.name == "internal"
    end

    test "returns second view if first doesn't match" do
      internal = View.new("internal", "localnets", ["corp.example.com"], true)
      external = View.new("external", "any", ["public.example.com"], false)

      {:ok, matched} = View.match_client({8, 8, 8, 8}, [internal, external])
      assert matched.name == "external"
    end

    test "returns error if no views match" do
      view = View.new("internal", "localhost")

      result = View.match_client({8, 8, 8, 8}, [view])
      assert result == {:error, :no_match}
    end

    test "evaluates views in order" do
      # Both views match, but first should win
      view1 = View.new("view1", "any")
      view2 = View.new("view2", "any")

      {:ok, matched} = View.match_client({192, 168, 1, 1}, [view1, view2])
      assert matched.name == "view1"
    end

    test "handles empty view list" do
      result = View.match_client({192, 168, 1, 1}, [])
      assert result == {:error, :no_match}
    end

    test "handles complex ACL rules" do
      # Create view with exception rules (allow specific subnet within denied range)
      acl =
        ACL.new("complex", [
          {:allow, {10, 1, 1, 0}, 24},
          {:deny, {10, 1, 0, 0}, 16},
          {:allow, {10, 0, 0, 0}, 8}
        ])

      view = View.new("complex", acl)

      # Should match specific allow
      {:ok, matched} = View.match_client({10, 1, 1, 1}, [view])
      assert matched.name == "complex"

      # Should be denied
      assert {:error, :no_match} = View.match_client({10, 1, 0, 1}, [view])

      # Should match broader allow
      {:ok, matched} = View.match_client({10, 0, 0, 1}, [view])
      assert matched.name == "complex"
    end
  end

  describe "add_zone/2" do
    test "adds zone to empty list" do
      view = View.new("internal", "localnets")
      view = View.add_zone(view, "corp.example.com")

      assert view.zones == ["corp.example.com"]
    end

    test "adds zone to existing list" do
      view = View.new("internal", "localnets", ["example.com"])
      view = View.add_zone(view, "corp.example.com")

      assert "corp.example.com" in view.zones
      assert "example.com" in view.zones
      assert length(view.zones) == 2
    end

    test "does not add duplicate zones" do
      view = View.new("internal", "localnets", ["example.com"])
      view = View.add_zone(view, "example.com")

      assert view.zones == ["example.com"]
    end
  end

  describe "remove_zone/2" do
    test "removes zone from list" do
      view = View.new("internal", "localnets", ["corp.example.com", "example.com"])
      view = View.remove_zone(view, "corp.example.com")

      assert view.zones == ["example.com"]
    end

    test "does nothing if zone not in list" do
      view = View.new("internal", "localnets", ["example.com"])
      view = View.remove_zone(view, "other.com")

      assert view.zones == ["example.com"]
    end

    test "handles empty zone list" do
      view = View.new("internal", "localnets")
      view = View.remove_zone(view, "example.com")

      assert view.zones == []
    end
  end

  describe "has_zone?/2" do
    test "returns true for existing zone" do
      view = View.new("internal", "localnets", ["corp.example.com"])

      assert View.has_zone?(view, "corp.example.com")
    end

    test "returns false for missing zone" do
      view = View.new("internal", "localnets", ["corp.example.com"])

      refute View.has_zone?(view, "other.com")
    end

    test "returns false for empty zone list" do
      view = View.new("internal", "localnets")

      refute View.has_zone?(view, "example.com")
    end
  end
end
