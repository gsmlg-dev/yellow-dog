defmodule DNS.Message.Question do
  @moduledoc """
  # DNS Question

  """
  require Logger

  alias DNS.Class
  alias DNS.Message.Question
  alias DNS.Message.Domain
  alias DNS.ResourceRecordType, as: RRType
  alias DNS.Message.Header

  @type t :: %__MODULE__{
          # name: binary
          name: Domain.t(),
          # type: uint16
          type: RRType.t(),
          # class: uint16
          class: Class.t()
        }

  defstruct name: Domain.new("."),
            type: RRType.new(<<1::16>>),
            class: Class.new(<<1::16>>)

  def new(name, type, class) do
    %__MODULE__{
      name: Domain.new(name),
      type: RRType.new(type),
      class: Class.new(class)
    }
  end

  @spec from_iodata(<<_::_*8>>, <<_::_*8>>) :: Question.t()
  def from_iodata(buffer, message \\ <<>>) do
    with domain <- Domain.from_iodata(buffer, message),
         <<_::binary-size(domain.size), type::16, class::16, _::binary>> <- buffer do
      %__MODULE__{name: domain, type: RRType.new(<<type::16>>), class: Class.new(<<class::16>>)}
    else
      error ->
        throw({:format_error, :question, error})
    end
  end

  @spec list_to_iodata([Question.t()]) :: binary()
  def list_to_iodata(list) when is_list(list) do
    list |> Enum.map(&DNS.to_iodata/1) |> Enum.join(<<>>)
  end

  @spec list_from_message(<<_::64, _::_*8>>) :: {[t()], non_neg_integer()}
  def list_from_message(<<header::binary-size(12), _::binary>> = message) do
    list_from_message(message, Header.qdcount(header))
  end

  def list_from_message(message) do
    throw({:format_error, :question, message})
  end

  @spec list_from_message(binary(), non_neg_integer()) :: {list(), non_neg_integer()}
  def list_from_message(<<_::binary-size(12), _::binary>> = _message, 0) do
    {[], 0}
  end

  def list_from_message(<<_::binary-size(12), buffer::binary>> = message, qdcount)
      when byte_size(message) >= 12 + 5 and is_integer(qdcount) and qdcount > 0 do
    {size, questions} =
      Enum.reduce(1..qdcount, {0, []}, fn _, {all_size, questions} ->
        question =
          from_iodata(binary_part(buffer, all_size, byte_size(buffer) - all_size), message)

        {all_size + question.name.size + 4, [question | questions]}
      end)

    {Enum.reverse(questions), size}
  end

  def list_from_message(message, qdcount) do
    throw({:format_error, :question, message, qdcount})
  end

  defimpl DNS.Parameter, for: DNS.Message.Question do
    @impl true
    def to_iodata(%DNS.Message.Question{} = question) do
      DNS.to_iodata(question.name) <>
        DNS.to_iodata(question.type) <> DNS.to_iodata(question.class)
    end
  end

  defimpl String.Chars, for: DNS.Message.Question do
    def to_string(question) do
      "#{question.name} #{question.type} #{question.class}"
    end
  end
end
