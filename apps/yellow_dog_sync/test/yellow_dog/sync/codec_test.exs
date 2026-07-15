defmodule YellowDog.Sync.CodecTest do
  use ExUnit.Case, async: true

  alias YellowDog.Sync.Codec
  alias YellowDog.Sync.Error

  test "rejects oversized whitespace followed by valid JSON before decoding" do
    raw_payload = :binary.copy(" ", Codec.max_document_bytes()) <> "null"

    assert_invalid(Codec.decode(raw_payload))
  end

  test "returns stable errors for malformed JSON input" do
    assert_invalid(Codec.decode(<<255>>))
    assert_invalid(Codec.decode("{\"unterminated\":"))
  end

  test "preflight ignores braces brackets and escaped quotes inside strings" do
    value = ~s([{"quoted":"\\""}])
    encoded = Jason.encode!(%{"value" => value})

    assert {:ok, %{"value" => ^value}} = Codec.decode(encoded)
  end

  test "accepts eight container levels through the Task 1 depth boundary" do
    payload = nested_payload(8)

    assert {:ok, encoded} = Codec.encode(payload)
    assert {:ok, ^payload} = Codec.decode(encoded)
  end

  test "preflight rejects nine container levels before JSON decoding" do
    payload = nested_payload(9)

    assert_invalid(Codec.encode(payload))
    assert_invalid(Codec.decode(Jason.encode!(payload)))
  end

  defp nested_payload(1), do: %{"value" => "ok"}
  defp nested_payload(depth), do: %{"nested" => nested_payload(depth - 1)}

  defp assert_invalid(result) do
    assert {:error, %Error{code: :invalid}} = result
  end
end
