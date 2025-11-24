defmodule DNS.Message.Record.Data.NSEC do
  alias DNS.Message.Domain

  @type t :: %__MODULE__{
          type: DNS.ResourceRecordType.t(),
          rdlength: 1..65535,
          raw: bitstring(),
          data: [binary()]
        }

  defstruct raw: nil, type: DNS.ResourceRecordType.new(47), rdlength: nil, data: nil

  def new({str, types}) do
    domain = Domain.new(str)
    rr_types = types |> Enum.map(&DNS.ResourceRecordType.new/1)
    raw = <<DNS.to_iodata(domain)::binary, to_raw(rr_types)::binary>>
    %__MODULE__{raw: raw, data: {domain, rr_types}, rdlength: byte_size(raw)}
  end

  def from_iodata(raw, message) do
    domain = Domain.from_iodata(raw, message)
    <<_::binary-size(domain.size), rest::binary>> = raw
    data = parse_raw(rest)
    %__MODULE__{raw: raw, data: {domain, data}, rdlength: byte_size(raw)}
  end

  defp parse_raw(raw, offset \\ 0, typeMaps \\ %{}) do
    <<_::binary-size(offset), window_block::8, bitmap_length::8, _::binary>> = raw
    offset = offset + 2
    bitmap = raw |> binary_part(offset, bitmap_length)

    rr_types =
      for i <- 0..(bitmap_length - 1) do
        <<n>> = bitmap |> binary_part(i, 1)

        if n != 0 do
          for j <- 0..7 do
            if Bitwise.<<<(1, 7 - j) |> Bitwise.&&&(n) |> Kernel.==(Bitwise.<<<(1, 7 - j)) do
              rr_type = window_block * 256 + i * 8 + j

              if rr_type != 41 && rr_type != 250 do
                [rr_type]
              else
                []
              end
            else
              []
            end
          end
        else
          []
        end
      end

    typeMaps = Map.put(typeMaps, window_block, rr_types |> flat_map_deep())
    offset = offset + bitmap_length

    if offset < byte_size(raw) do
      parse_raw(raw, offset, typeMaps)
    else
      rr_types = Enum.flat_map(typeMaps, fn {_, rr_types} -> rr_types end)
      rr_types |> Enum.map(&DNS.ResourceRecordType.new/1)
    end
  end

  defp flat_map_deep(list) do
    Enum.flat_map(list, fn
      item when is_list(item) -> flat_map_deep(item)
      item -> [item]
    end)
  end

  defp to_raw(types) do
    values =
      types
      |> Enum.map(fn %DNS.ResourceRecordType{value: <<val::16>>} -> val end)
      |> Enum.sort()

    {_, raw_bytes, _} =
      Enum.reduce(0..256, {values, <<>>, -1}, fn i, {values, raw_bytes, window} ->
        if values == [] do
          {values, raw_bytes, window + 1}
        else
          step = i * 256
          {types_to_go, values} = move_types_to_go([], values, step)

          if types_to_go |> Enum.count() > 0 do
            bitmap = <<>>
            pos = 0
            outputs = consume_types_to_go(types_to_go, pos, bitmap, window, step)

            {values, <<raw_bytes::binary, outputs::binary>>, window + 1}
          else
            {values, raw_bytes, window + 1}
          end
        end
      end)

    raw_bytes
  end

  defp move_types_to_go(types_to_go, [], _), do: {types_to_go, []}

  defp move_types_to_go(types_to_go, values, step) do
    [first | rest_values] = values

    if first < step do
      types_to_go = [first | types_to_go]
      move_types_to_go(types_to_go, rest_values, step)
    else
      {types_to_go, values}
    end
  end

  defp consume_types_to_go(types_to_go, pos, bitmap, window, step) do
    byte = 0
    pos = pos + 8

    {moved_types_to_go, byte} =
      move_types_to_go_to_bitmap(types_to_go, byte, pos, bitmap, window, step)

    bitmap = <<bitmap::binary, byte::8>>
    output = <<window::8, byte_size(bitmap)::8, bitmap::binary>>

    if moved_types_to_go == [] do
      output
    else
      rest = consume_types_to_go(moved_types_to_go, pos, bitmap, window, step)
      <<output::binary, rest::binary>>
    end
  end

  defp move_types_to_go_to_bitmap([], byte, _pos, _bitmap, _window, _step), do: {[], byte}

  defp move_types_to_go_to_bitmap(types_to_go, byte, pos, bitmap, window, step) do
    [first | rest_types_to_go] = types_to_go

    if first < pos + step - 256 do
      move_left = pos - 1 - (first - (step - 256))
      bit_or = 1 |> Bitwise.<<<(move_left)
      byte = byte |> Bitwise.bor(bit_or)
      move_types_to_go_to_bitmap(rest_types_to_go, byte, pos, bitmap, window, step)
    else
      {types_to_go, byte}
    end
  end

  defimpl DNS.Parameter, for: DNS.Message.Record.Data.NSEC do
    @impl true
    def to_iodata(%DNS.Message.Record.Data.NSEC{raw: raw, rdlength: rdlength}) do
      <<rdlength::16, raw::binary>>
    end
  end

  defimpl String.Chars, for: DNS.Message.Record.Data.NSEC do
    def to_string(%DNS.Message.Record.Data.NSEC{data: {domain, types}}) do
      "#{domain} #{types |> Enum.join(" ")}"
    end
  end
end
