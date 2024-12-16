defmodule YellowDog.DNS.Message.Question do
  @moduledoc """
  # DNS Question

  """
  require Logger

  alias YellowDog.DNS.Message.Question
  alias YellowDog.DNS.Class
  alias YellowDog.DNS.ResourceRecord.Type, as: RType
  alias YellowDog.DNS.Message.Header

  import YellowDog.DNS.Message.NameUtils

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

  @spec to_buffer(Question.t()) :: <<_::32, _::_*8>>
  def to_buffer(%__MODULE__{} = question) do
    <<name_to_buffer(question.name)::binary, question.type::16, question.class::16>>
  end

  @spec from_buffer(<<_::40, _::_*8>>) :: {pos_integer(), Question.t()}
  def from_buffer(buffer, message \\ <<>>) do
    with {name_length, name} <- name_from_buffer(buffer, message),
         <<_::binary-size(name_length), type::16, class::16, _::binary>> <- buffer do
      {name_length + 4, %__MODULE__{name: name, type: type, class: class}}
    else
      error ->
        throw({:format_error, :question, error})
    end
  end

  @spec new(binary(), integer(), integer()) :: Question.t()
  def new(name, type, class) do
    new_name = name |> name_to_buffer() |> name_from_buffer() |> elem(1)

    %__MODULE__{
      name: new_name,
      type: type,
      class: class
    }
  end

  @spec list_to_buffer([Question.t()]) :: binary()
  def list_to_buffer(list) when is_list(list) do
    list |> Enum.map(&to_buffer/1) |> Enum.join(<<>>)
  end

  @spec list_from_message(binary()) :: {non_neg_integer(), list()}
  def list_from_message(<<header::binary-size(12), _::binary>> = message) do
    list_from_message(message, Header.qdcount(header))
  end
  def list_from_message(message) do
    Logger.error("Error list_from_message/1: #{inspect(message)}")
    throw({:format_error, :question, message})
  end

  @spec list_from_message(binary(), non_neg_integer()) :: {non_neg_integer(), list()}
  def list_from_message(<<_::binary-size(12), _::binary>> = _message, 0) do
    {0, []}
  end
  def list_from_message(<<_::binary-size(12), buffer::binary>> = message, qdcount)
      when byte_size(message) >= 12 + 5 and is_integer(qdcount) and qdcount > 0 do
    Enum.reduce(1..qdcount, {0, []}, fn _, {all_size, questions} ->
      {size, question} =
        from_buffer(binary_part(buffer, all_size, byte_size(buffer) - all_size), message)

      {all_size + size, questions ++ [question]}
    end)
  end
  def list_from_message(message, qdcount) do
    Logger.error("Error list_from_message/2: #{inspect(message)} #{inspect(qdcount)}")
    throw({:format_error, :question, message})
  end

  @spec to_print(Question.t()) :: binary()
  def to_print(question = %__MODULE__{}) do
    "#{question.name} #{RType.to_print(question.type)} #{Class.to_print(question.class)}"
  rescue
    e ->
      """
      QUESTION Error:
      #{inspect(e)}
      #{inspect(question)}
      """
  end
end
