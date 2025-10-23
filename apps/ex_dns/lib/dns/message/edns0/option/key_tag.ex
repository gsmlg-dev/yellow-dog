defmodule DNS.Message.EDNS0.Option.KeyTag do
  @moduledoc """
  EDNS0.Option.KeyTag [RFC8145](https://datatracker.ietf.org/doc/html/rfc8145)

  The edns-key-tag option is used to communicate DNSSEC key tags that
  a resolver trusts for a particular zone.

  Option Format:

                        1 1 1 1 1 1 1 1 1 1 2 2 2 2 2 2 2 2 2 2 3 3
    0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    |        OPTION-CODE = 14       |       OPTION-LENGTH           |
    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    |                                                               |
    /                      KEY-TAG LIST                             /
    /                                                               /
    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+

  - KEY-TAG LIST: Variable length, list of DNSSEC key tags (2 octets each)
  """
  alias DNS.Message.EDNS0.OptionCode

  @type t :: %__MODULE__{
          code: OptionCode.t(),
          length: 0..65535,
          data: [integer()]
        }

  defstruct code: OptionCode.new(14), length: nil, data: []

  @spec new([integer()]) :: t()
  def new(key_tag_list) do
    len = length(key_tag_list) * 2
    %__MODULE__{length: len, data: key_tag_list}
  end

  def from_iodata(<<14::16, length::16, key_tag_data::binary-size(length)>>) do
    key_tags =
      for <<key_tag::16 <- key_tag_data>> do
        key_tag
      end

    %__MODULE__{length: length, data: key_tags}
  end

  defimpl DNS.Parameter, for: DNS.Message.EDNS0.Option.KeyTag do
    @impl true
    def to_iodata(%DNS.Message.EDNS0.Option.KeyTag{data: key_tag_list}) do
      key_tag_binary =
        key_tag_list
        |> Enum.map(fn tag -> <<tag::16>> end)
        |> Enum.join()

      <<14::16, byte_size(key_tag_binary)::16, key_tag_binary::binary>>
    end
  end

  defimpl String.Chars, for: DNS.Message.EDNS0.Option.KeyTag do
    def to_string(%DNS.Message.EDNS0.Option.KeyTag{code: code, data: key_tag_list}) do
      key_tags = Enum.join(key_tag_list, ",")
      "#{code}: [#{key_tags}]"
    end
  end
end
