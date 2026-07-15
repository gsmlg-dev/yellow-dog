defmodule YellowDog.Sync.BoundsTest do
  use ExUnit.Case, async: true

  alias YellowDog.Sync.Bounds
  alias YellowDog.Sync.Error

  test "accepts IDs at the maximum size and rejects larger IDs" do
    assert {:ok, id} = Bounds.id(String.duplicate("i", Bounds.max_id_bytes()))
    assert byte_size(id) == Bounds.max_id_bytes()

    assert_invalid(Bounds.id(String.duplicate("i", Bounds.max_id_bytes() + 1)))
  end

  test "rejects invalid UTF-8 text values" do
    assert_invalid(Bounds.id(<<255>>))
    assert_invalid(Bounds.operation(<<255>>))
    assert_invalid(Bounds.message(<<255>>))
  end

  test "accepts operations at the maximum size and rejects larger operations" do
    assert {:ok, operation} =
             Bounds.operation(String.duplicate("o", Bounds.max_operation_bytes()))

    assert byte_size(operation) == Bounds.max_operation_bytes()

    assert_invalid(Bounds.operation(String.duplicate("o", Bounds.max_operation_bytes() + 1)))
  end

  test "accepts messages at the maximum size and rejects larger messages" do
    assert {:ok, message} = Bounds.message(String.duplicate("m", Bounds.max_message_bytes()))
    assert byte_size(message) == Bounds.max_message_bytes()

    assert_invalid(Bounds.message(String.duplicate("m", Bounds.max_message_bytes() + 1)))
  end

  test "accepts maps at the maximum size and rejects larger maps" do
    assert {:ok, map} = Bounds.map(Map.new(1..Bounds.max_map_entries(), &{&1, &1}))
    assert map_size(map) == Bounds.max_map_entries()

    assert_invalid(Bounds.map(Map.new(1..(Bounds.max_map_entries() + 1), &{&1, &1})))
  end

  test "accepts lists at the maximum size and rejects larger lists" do
    assert {:ok, list} = Bounds.list(Enum.to_list(1..Bounds.max_list_entries()))
    assert length(list) == Bounds.max_list_entries()

    assert_invalid(Bounds.list(Enum.to_list(1..(Bounds.max_list_entries() + 1))))
  end

  test "accepts payloads at the maximum size and rejects larger payloads" do
    assert {:ok, payload} = Bounds.payload(:binary.copy(<<0>>, Bounds.max_payload_bytes()))
    assert byte_size(payload) == Bounds.max_payload_bytes()

    assert_invalid(Bounds.payload(:binary.copy(<<0>>, Bounds.max_payload_bytes() + 1)))
  end

  defp assert_invalid(result) do
    assert {:error, %Error{code: :invalid}} = result
  end
end
