defmodule DNS.Message.EDNS0.Option.NSID do
  @moduledoc """
  EDNS0.Option.NSID [RFC5001](https://datatracker.ietf.org/doc/html/rfc5001)

  The Name Server ID (NSID) option is used to identify a specific name
  server that responded to a DNS query.

  Option Format:

                        1 1 1 1 1 1 1 1 1 1 2 2 2 2 2 2 2 2 2 2 3 3
    0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    |        OPTION-CODE = 3        |       OPTION-LENGTH           |
    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    |                                                               |
    /                          NSID DATA                            /
    /                                                               /
    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+

  - NSID DATA: Variable length, up to 65535 octets
  """
  alias DNS.Message.EDNS0.OptionCode

  @type t :: %__MODULE__{
          code: OptionCode.t(),
          length: 0..65535,
          data: binary()
        }

  defstruct code: OptionCode.new(3), length: nil, data: nil

  @spec new(binary()) :: t()
  def new(nsid_data) do
    len = byte_size(nsid_data)
    %__MODULE__{length: len, data: nsid_data}
  end

  def from_iodata(<<3::16, length::16, nsid_data::binary-size(length)>>) do
    %__MODULE__{length: length, data: nsid_data}
  end

  defimpl DNS.Parameter, for: DNS.Message.EDNS0.Option.NSID do
    @impl true
    def to_iodata(%DNS.Message.EDNS0.Option.NSID{data: nsid_data}) do
      <<3::16, byte_size(nsid_data)::16, nsid_data::binary>>
    end
  end

  defimpl String.Chars, for: DNS.Message.EDNS0.Option.NSID do
    def to_string(%DNS.Message.EDNS0.Option.NSID{code: code, data: nsid_data}) do
      "#{code}: #{Base.encode16(nsid_data)}"
    end
  end
end
