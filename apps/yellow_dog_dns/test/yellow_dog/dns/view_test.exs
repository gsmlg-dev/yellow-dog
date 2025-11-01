defmodule YellowDog.Dns.ViewTest do
  use ExUnit.Case, async: true

  alias YellowDog.Dns.View

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
end
