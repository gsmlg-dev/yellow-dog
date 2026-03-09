defmodule YellowDog.Resolved.DiscoveryTest do
  use ExUnit.Case, async: true

  describe "EDNS option encoding" do
    test "generates 16-byte instance ID" do
      uuid = :crypto.strong_rand_bytes(16)
      assert byte_size(uuid) == 16
    end
  end
end
