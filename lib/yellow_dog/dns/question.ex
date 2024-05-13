def YellowDog.DNS.Question do
  @moduledoc """
  # DNS Question

  """

  @type t :: %__MODULE__{
    name: String.t(), # ID: 16bit if 0 generate RandomID
    type: integer(), # QR: 1bit  query (0), or a response (1)
    class: integer(), # OPCode: 4bit YellowDog.DNS.OpCode.t(),
  }

  defstruct name: ".",
    type: YellowDog.DNS.RRType.a(),
    class: YellowDog.DNS.Class.internet()

  def to_buffer(list) when is_list(list) do
    list |> Enum.map(&to_buffer/1)
  end
  def to_buffer(%__MODULE__{} = question) do
    <<question.name::binary, 0x00, question.type::16, question.class::16>>
  end


end
