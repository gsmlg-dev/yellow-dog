defmodule YellowDog.Resolved.UpstreamTest do
  use ExUnit.Case, async: true

  alias YellowDog.Resolved.Upstream

  describe "normalize/1" do
    test "bare IPv4 tuple normalizes to port 53" do
      assert Upstream.normalize({1, 1, 1, 1}) == {{1, 1, 1, 1}, 53}
    end

    test "{ip, port} tuple passes through unchanged" do
      assert Upstream.normalize({{8, 8, 8, 8}, 5353}) == {{8, 8, 8, 8}, 5353}
    end

    test "bare IPv6 tuple normalizes to port 53" do
      ipv6 = {0, 0, 0, 0, 0, 0, 0, 1}
      assert Upstream.normalize(ipv6) == {ipv6, 53}
    end

    test "{ipv6, port} tuple passes through" do
      ipv6 = {0, 0, 0, 0, 0, 0, 0, 1}
      assert Upstream.normalize({ipv6, 853}) == {ipv6, 853}
    end
  end

  describe "format/1" do
    test "bare IPv4 tuple formats without port" do
      assert Upstream.format({1, 1, 1, 1}) == "1.1.1.1"
    end

    test "{ip, port} tuple formats with port" do
      assert Upstream.format({{8, 8, 8, 8}, 5353}) == "8.8.8.8:5353"
    end

    test "bare IPv6 tuple formats without port" do
      result = Upstream.format({0, 0, 0, 0, 0, 0, 0, 1})
      assert result == "::1"
    end

    test "{ipv6, port} formats with port" do
      result = Upstream.format({{0, 0, 0, 0, 0, 0, 0, 1}, 853})
      assert result == "::1:853"
    end
  end
end
