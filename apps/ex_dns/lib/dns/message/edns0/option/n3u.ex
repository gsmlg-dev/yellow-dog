defmodule DNS.Message.EDNS0.Option.N3U do
  @moduledoc """
  EDNS0.Option.N3U [RFC6975](https://datatracker.ietf.org/doc/html/rfc6975)

  NSEC3 Hash Understood (N3U) option is used to indicate which NSEC3 hash
  algorithms a resolver understands.

  Option Format:

                        1 1 1 1 1 1 1 1 1 1 2 2 2 2 2 2 2 2 2 2 3 3
    0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    |        OPTION-CODE = 7        |       OPTION-LENGTH           |
    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    |                                                               |
    /                      ALGORITHM LIST                           /
    /                                                               /
    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+

  - ALGORITHM LIST: Variable length, list of NSEC3 hash algorithm codes
  """
  alias DNS.Message.EDNS0.OptionCode

  @type t :: %__MODULE__{
          code: OptionCode.t(),
          length: 0..65535,
          data: [integer()]
        }

  defstruct code: OptionCode.new(7), length: nil, data: []

  @spec new([integer()]) :: t()
  def new(algorithm_list) do
    len = length(algorithm_list)
    %__MODULE__{length: len, data: algorithm_list}
  end

  def from_iodata(<<7::16, length::16, algorithm_list::binary-size(length)>>) do
    algorithms = :binary.bin_to_list(algorithm_list)
    %__MODULE__{length: length, data: algorithms}
  end

  defimpl DNS.Parameter, for: DNS.Message.EDNS0.Option.N3U do
    @impl true
    def to_iodata(%DNS.Message.EDNS0.Option.N3U{data: algorithm_list}) do
      algorithm_binary = :binary.list_to_bin(algorithm_list)
      <<7::16, byte_size(algorithm_binary)::16, algorithm_binary::binary>>
    end
  end

  defimpl String.Chars, for: DNS.Message.EDNS0.Option.N3U do
    def to_string(%DNS.Message.EDNS0.Option.N3U{code: code, data: algorithm_list}) do
      algorithms = Enum.join(algorithm_list, ",")
      "#{code}: [#{algorithms}]"
    end
  end
end
