defmodule YellowDog.DNS.Message.Question do
  @moduledoc """
  # DNS Question

  """

  alias YellowDog.DNS.Class
  alias YellowDog.DNS.ResourceRecord.Type, as: RType

  @type t :: %__MODULE__{
          # ID: 16bit if 0 generate RandomID
          name: String.t(),
          # QR: 1bit  query (0), or a response (1)
          type: integer(),
          # OPCode: 4bit YellowDog.DNS.OpCode.t(),
          class: integer()
        }

  defstruct name: ".",
            type: RType.a(),
            class: Class.internet()

  def to_buffer(list) when is_list(list) do
    list |> Enum.map(&to_buffer/1)
  end

  def to_buffer(%__MODULE__{} = question) do
    <<question.name::binary, 0x00, question.type::16, question.class::16>>
  end
end
