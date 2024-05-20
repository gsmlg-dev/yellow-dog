defmodule YellowDog.DNS.Message.Question do
  @moduledoc """
  # DNS Question

  """

  alias YellowDog.DNS.Class
  alias YellowDog.DNS.ResourceRecord.Type, as: RType
  alias YellowDog.DNS.Message
  alias YellowDog.DNS.Message.Header

  @type t :: %__MODULE__{
          # name: binary
          name: String.t(),
          # type: uint16
          type: integer(),
          # class: uint16
          class: integer()
        }

  defstruct name: ".",
            type: RType.a(),
            class: Class.internet()

  def to_buffer(%__MODULE__{} = question) do
    <<question.name::binary, 0x00, question.type::16, question.class::16>>
  end

  def from_buffer(buffer, message \\ <<>>) do
    {name, name_length} = Message.name_from_buffer(buffer, message)

    cond do
      <<_::binary-size(name_length), type::16, class::16>> = buffer ->
        {name_length + 4, %__MODULE__{name: name, type: type, class: class}}

      true ->
        throw(:invalid_dns_message)
    end
  end

  def list_to_buffer(list) when is_list(list) do
    list |> Enum.map(&to_buffer/1) |> Enum.join(<<>>)
  end

  def list_from_message(<<header::binary-size(12), _>> = message) when byte_size(message) >= 12 do
    list_from_message(message, Header.qdcount(header))
  end

  def list_from_message(<<_::binary-size(12), _>> = message, 0) when byte_size(message) >= 12 do
    {0, []}
  end

  def list_from_message(<<_::binary-size(12), buffer::binary>> = message, qdcount)
      when byte_size(message) >= 12 and is_integer(qdcount) and qdcount > 0 do
    {byte_length, questions} =
      Enum.reduce(0..qdcount, {0, []}, fn _, {all_size, questions} ->
        {size, question} = from_buffer(binary_part(buffer, all_size, byte_size(buffer)), message)
        {all_size + size, [question | questions]}
      end)

    {byte_length, questions |> Enum.reverse()}
  end
end
