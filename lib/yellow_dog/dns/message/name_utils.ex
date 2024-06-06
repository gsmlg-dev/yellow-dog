defmodule YellowDog.DNS.Message.NameUtils do
  @moduledoc """
  Convert Domain Name bianry from DNS message bitstring.
  Support uncompress domain name from message.

  # USEAGE

      import YellowDog.DNS.Message.NameUtils

  * name_to_buffer(".") :: <<0>>
  * name_from_buffer(<<0>>) :: {1, "."}

  TODO: Add method to compress domain name in message.
  """

  @doc """
  Encode domain name to dns message in bitstring.
  """
  @spec name_to_buffer(binary()) :: bitstring()
  def name_to_buffer(name) do
    case String.split(name, ".") |> Enum.filter(&(&1 != "")) do
      [] ->
        <<0>>

      list ->
        list
        |> Enum.reverse()
        |> Enum.reduce(<<0>>, fn part, acc ->
          part_length = byte_size(part)
          <<part_length::8, part::binary-size(part_length), acc::binary>>
        end)
    end
  end

  @doc """
  Get name from bitstring, uncompress name in message
  """
  @spec name_from_buffer(bitstring(), bitstring()) :: {integer(), nonempty_binary()}
  def name_from_buffer(buffer, message \\ <<>>)
  def name_from_buffer(<<size::8, _::binary>>, _) when size == 0, do: {1, "."}

  def name_from_buffer(<<size::8, pos::8, _::binary>>, message) when size == 0xC0 do
    case message do
      <<_::binary-size(pos), next::8, next_buffer::binary>> when next > 0 and next < 64 ->
        {_, name} = name_from_buffer(<<next::8, next_buffer::binary>>, message)
        {2, name}

      <<_::binary-size(pos), next::8, next_pos::8, next_buffer::binary>>
      when next == 0xC0 and pos != next_pos ->
        {_, name} = name_from_buffer(<<next::8, next_pos::8, next_buffer::binary>>, message)
        {2, name}

      _ ->
        throw(FormatError)
    end
  end

  def name_from_buffer(<<size::8, rest::binary>>, message)
      when size > 0 and size < 64 do
    case rest do
      <<part::binary-size(size), next::8, _::binary>> when next == 0 ->
        {1 + size + 1, part <> "."}

      <<part::binary-size(size), next::8, next_pos::8, last_buffer::binary>> when next == 0xC0 ->
        {_, compressed_name} =
          name_from_buffer(<<next::8, next_pos::8, last_buffer::binary>>, message)

        {1 + size + 2, part <> "." <> compressed_name}

      <<part::binary-size(size), next::8, next_buffer::binary>> when next > 0 and next < 64 ->
        {last_size, last_name} = name_from_buffer(<<next, next_buffer::binary>>, message)
        {1 + size + last_size, part <> "." <> last_name}

      <<_::binary-size(size), _::binary>> ->
        throw(FormatError)
    end
  end

  def name_from_buffer(buffer, message) do
    throw({:invalid_format, buffer, message})
  end
end
