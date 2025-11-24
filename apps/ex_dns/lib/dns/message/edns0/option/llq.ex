defmodule DNS.Message.EDNS0.Option.LLQ do
  @moduledoc """
  EDNS0.Option.LLQ [RFC8764](https://datatracker.ietf.org/doc/html/rfc8764)

  The DNS Long-Lived Queries (LLQ) option is used to enable DNS clients
  to receive asynchronous notifications when resource records change.

  Option Format:

                        1 1 1 1 1 1 1 1 1 1 2 2 2 2 2 2 2 2 2 2 3 3
    0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    |        OPTION-CODE = 1        |       OPTION-LENGTH = 18      |
    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    |          LLQ-Version          |              LLQ-Opcode        |
    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    |                            LLQ-ID                             |
    |                                                               |
    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    |                          LLQ-LEASE-LIFE                       |
    |                                                               |
    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+

  - LLQ-Version: 2 octets, must be set to 1
  - LLQ-Opcode: 2 octets, identifies the LLQ operation
  - LLQ-ID: 8 octets, unique identifier for the LLQ
  - LLQ-LEASE-LIFE: 4 octets, lease duration in seconds
  """
  alias DNS.Message.EDNS0.OptionCode

  @type t :: %__MODULE__{
          code: OptionCode.t(),
          length: 18,
          data: {
            version :: 0..65535,
            opcode :: 0..65535,
            id :: <<_::64>>,
            lease_life :: 0..4_294_967_295
          }
        }

  defstruct code: OptionCode.new(1), length: 18, data: nil

  @spec new({integer(), integer(), binary(), integer()}) :: t()
  def new({version, opcode, id, lease_life}) do
    %__MODULE__{data: {version, opcode, id, lease_life}}
  end

  def from_iodata(<<1::16, 18::16, version::16, opcode::16, id::64, lease_life::32>>) do
    %__MODULE__{data: {version, opcode, <<id::64>>, lease_life}}
  end

  defimpl DNS.Parameter, for: DNS.Message.EDNS0.Option.LLQ do
    @impl true
    def to_iodata(%DNS.Message.EDNS0.Option.LLQ{
          data: {version, opcode, <<id::64>>, lease_life}
        }) do
      <<1::16, 18::16, version::16, opcode::16, id::64, lease_life::32>>
    end
  end

  defimpl String.Chars, for: DNS.Message.EDNS0.Option.LLQ do
    def to_string(%DNS.Message.EDNS0.Option.LLQ{
          code: code,
          data: {version, opcode, id, lease_life}
        }) do
      "#{code}: v#{version} op#{opcode} id:#{Base.encode16(id)} lease:#{lease_life}s"
    end
  end
end
