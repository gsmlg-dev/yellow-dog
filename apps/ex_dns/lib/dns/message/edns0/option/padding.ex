defmodule DNS.Message.EDNS0.Option.Padding do
  @moduledoc """
  EDNS0.Option.Padding [RFC7830](https://datatracker.ietf.org/doc/html/rfc7830)

  The Padding option is used to pad DNS messages to a specific size
  to prevent traffic analysis attacks.

  Option Format:

                        1 1 1 1 1 1 1 1 1 1 2 2 2 2 2 2 2 2 2 2 3 3
    0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    |        OPTION-CODE = 12       |       OPTION-LENGTH           |
    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    |                                                               |
    /                        PADDING DATA                           /
    /                                                               /
    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+

  - PADDING DATA: Variable length, typically zeros or random data
  """
  alias DNS.Message.EDNS0.OptionCode

  @type t :: %__MODULE__{
          code: OptionCode.t(),
          length: 0..65535,
          data: binary()
        }

  defstruct code: OptionCode.new(12), length: nil, data: nil

  @spec new(binary()) :: t()
  def new(padding_data) when is_binary(padding_data) do
    len = byte_size(padding_data)
    %__MODULE__{length: len, data: padding_data}
  end

  @spec new(integer()) :: t()
  def new(padding_length) when is_integer(padding_length) do
    padding_data = :binary.copy(<<0>>, padding_length)
    %__MODULE__{length: padding_length, data: padding_data}
  end

  def from_iodata(<<12::16, length::16, padding_data::binary-size(length)>>) do
    %__MODULE__{length: length, data: padding_data}
  end

  defimpl DNS.Parameter, for: DNS.Message.EDNS0.Option.Padding do
    @impl true
    def to_iodata(%DNS.Message.EDNS0.Option.Padding{data: padding_data}) do
      <<12::16, byte_size(padding_data)::16, padding_data::binary>>
    end
  end

  defimpl String.Chars, for: DNS.Message.EDNS0.Option.Padding do
    def to_string(%DNS.Message.EDNS0.Option.Padding{code: code, length: length}) do
      "#{code}: #{length} bytes"
    end
  end
end
