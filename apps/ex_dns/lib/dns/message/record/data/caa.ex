defmodule DNS.Message.Record.Data.CAA do
  @moduledoc """
  DNS CAA Record (Type 257)

  The CAA (Certification Authority Authorization) record allows domain owners
  to specify which certificate authorities are authorized to issue certificates
  for their domain.

  RFC 6844 defines the CAA record format:
  - Flags: 1 octet
  - Tag Length: 1 octet
  - Tag: variable length
  - Value: variable length
  """
  alias DNS.ResourceRecordType, as: RRType

  @type t :: %__MODULE__{
          type: RRType.t(),
          rdlength: 0..65535,
          raw: bitstring(),
          data: {flags :: 0..255, tag :: binary(), value :: binary()}
        }

  defstruct raw: nil, type: RRType.new(257), rdlength: nil, data: nil

  @spec new({integer(), binary(), binary()}) :: t()
  def new({flags, tag, value}) do
    tag_length = byte_size(tag)
    raw = <<flags::8, tag_length::8, tag::binary, value::binary>>

    %__MODULE__{
      raw: raw,
      data: {flags, tag, value},
      rdlength: byte_size(raw)
    }
  end

  @spec from_iodata(bitstring(), bitstring() | nil) :: t()
  def from_iodata(raw, _message \\ nil) do
    <<flags::8, tag_length::8, tag::binary-size(tag_length), value::binary>> = raw

    %__MODULE__{
      raw: raw,
      data: {flags, tag, value},
      rdlength: byte_size(raw)
    }
  end

  defimpl DNS.Parameter, for: DNS.Message.Record.Data.CAA do
    @impl true
    def to_iodata(%DNS.Message.Record.Data.CAA{data: data}) do
      {flags, tag, value} = data
      tag_length = byte_size(tag)
      size = 2 + tag_length + byte_size(value)

      <<size::16, flags::8, tag_length::8, tag::binary, value::binary>>
    end
  end

  defimpl String.Chars, for: DNS.Message.Record.Data.CAA do
    def to_string(%DNS.Message.Record.Data.CAA{data: data}) do
      {flags, tag, value} = data
      "#{flags} #{tag} \"#{value}\""
    end
  end
end
