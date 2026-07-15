defmodule YellowDog.Sync.DigestTest do
  use ExUnit.Case, async: true

  alias YellowDog.Sync.Codec
  alias YellowDog.Sync.Digest
  alias YellowDog.Sync.Error

  test "canonical JSON and its digest are deterministic for nested maps" do
    left = %{"b" => [%{"z" => true, "a" => nil}], "a" => %{"d" => 2, "c" => 1}}
    right = %{"a" => %{"c" => 1, "d" => 2}, "b" => [%{"a" => nil, "z" => true}]}

    assert {:ok, "{\"a\":{\"c\":1,\"d\":2},\"b\":[{\"a\":null,\"z\":true}]}"} = Codec.encode(left)
    assert {:ok, digest} = Digest.calculate(left)
    assert {:ok, ^digest} = Digest.calculate(right)
    assert digest =~ ~r/\A[0-9a-f]{64}\z/
    assert :ok = Digest.verify(right, digest)
  end

  test "rejects invalid JSON-safe values and incorrect digest values with stable errors" do
    assert_invalid(Codec.encode(%{field: "atom key"}))
    assert_invalid(Codec.encode(%{"value" => :atom}))
    assert_invalid(Codec.encode(%{"value" => {"tuple"}}))
    assert_invalid(Digest.verify(%{}, String.duplicate("A", 64)))
    assert_invalid(Digest.verify(%{}, String.duplicate("0", 64)))
  end

  defp assert_invalid(result) do
    assert {:error, %Error{code: :invalid}} = result
  end
end
