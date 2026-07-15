defmodule YellowDog.Sync.CodecTest do
  use ExUnit.Case, async: true

  alias YellowDog.Sync.Bounds
  alias YellowDog.Sync.Codec
  alias YellowDog.Sync.Error

  test "rejects raw JSON input over the payload boundary before decoding" do
    raw_payload = :binary.copy(" ", Bounds.max_payload_bytes() + 1)

    assert_invalid(Codec.decode(raw_payload))
  end

  test "returns stable errors for malformed JSON input" do
    assert_invalid(Codec.decode(<<255>>))
    assert_invalid(Codec.decode("{\"unterminated\":"))
  end

  test "accepts canonical nesting through the Task 1 depth boundary" do
    payload = nested_payload(7)

    assert {:ok, encoded} = Codec.encode(payload)
    assert {:ok, ^payload} = Codec.decode(encoded)
  end

  test "rejects canonical nesting beyond the Task 1 depth boundary" do
    payload = nested_payload(8)

    assert_invalid(Codec.encode(payload))
    assert_invalid(Codec.decode(Jason.encode!(payload)))
  end

  defp nested_payload(1), do: %{"value" => "ok"}
  defp nested_payload(depth), do: %{"nested" => nested_payload(depth - 1)}

  defp assert_invalid(result) do
    assert {:error, %Error{code: :invalid}} = result
  end
end
