defmodule YellowDog.DNS.Message.EDNS0Test do
  use ExUnit.Case
  doctest YellowDog

  alias YellowDog.DNS.Message.EDNS0

  test "Test EDNS0 message creation" do
    edns0 = EDNS0.new()

    buffer = edns0 |> EDNS0.to_buffer()

    assert <<0::8, 41::16, 0::16, 0::8, 0::8, 0::1, 0::15, 0::16>> = buffer

    edns0 = EDNS0.new()

    edns0 = %EDNS0{edns0 | do_bit: 1}
    buffer = edns0 |> EDNS0.to_buffer()

    assert <<0::8, 41::16, 0::16, 0::8, 0::8, 1::1, 0::15, 0::16>> = buffer

    edns0 = EDNS0.new()

    edns0 = %EDNS0{edns0 | udp_payload: 4096}
    buffer = edns0 |> EDNS0.to_buffer()

    assert <<0::8, 41::16, 4096::16, 0::8, 0::8, 0::1, 0::15, 0::16>> = buffer

    edns0 = EDNS0.new()

    edns0 = %EDNS0{edns0 | extended_rcode: 24, version: 5}
    buffer = edns0 |> EDNS0.to_buffer()

    assert <<0::8, 41::16, 0::16, 24::8, 5::8, 0::1, 0::15, 0::16>> = buffer
  end

  test "Test EDNS0 message add option ECS" do
    edns0 = EDNS0.new()

    buffer = edns0 |> EDNS0.to_buffer()

    assert <<0::8, 41::16, 0::16, 0::8, 0::8, 0::1, 0::15, 0::16>> = buffer

    edns0 = edns0 |> EDNS0.add_option(8, {{1, 2, 4, 8}, 24, 0})

    buffer = edns0 |> EDNS0.to_buffer()

    assert <<0, 0, 41, 0, 0, 0, 0, 0, 0, 0, 11, 0, 8, 0, 7, 0, 1, 24, 0, 1, 2, 4>> = buffer
  end

  test "Test EDNS0 message parse" do
    buffer = <<0, 0, 41, 0, 0, 0, 0, 0, 0, 0, 11, 0, 8, 0, 7, 0, 1, 24, 0, 1, 2, 4>>

    edns0 = EDNS0.from_buffer(buffer)

    assert 1 = length(edns0.options)

    option = List.first(edns0.options)

    assert {8, {{1, 2, 4, 0}, 24, 0}} = option
  end

  test "Test EDNS0 message add option cookie" do
    edns0 = EDNS0.new()

    buffer = edns0 |> EDNS0.to_buffer()

    assert <<0::8, 41::16, 0::16, 0::8, 0::8, 0::1, 0::15, 0::16>> = buffer

    edns0 = edns0 |> EDNS0.add_option(10, {<<24, 37, 61, 52, 248, 137, 246, 8>>, nil})

    buffer = edns0 |> EDNS0.to_buffer()

    assert <<0, 0, 41, 0, 0, 0, 0, 0, 0, 0, 12, 0, 10, 0, 8, 24, 37, 61, 52, 248, 137, 246, 8>> =
             buffer
  end
end
