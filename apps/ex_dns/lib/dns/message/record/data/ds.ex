defmodule DNS.Message.Record.Data.DS do
  @moduledoc """
  DNS DS Record (Type 43)

  The DS (Delegation Signer) record is used in DNSSEC to establish a chain of trust
  between parent and child zones. It contains a hash of a DNSKEY record.

  RFC 4034 defines the DS record format:
  - Key Tag: 2 octets
  - Algorithm: 1 octet
  - Digest Type: 1 octet
  - Digest: variable length
  """
  alias DNS.ResourceRecordType, as: RRType

  @type t :: %__MODULE__{
          type: RRType.t(),
          rdlength: 0..65535,
          raw: bitstring(),
          data:
            {key_tag :: 0..65535, algorithm :: 0..255, digest_type :: 0..255, digest :: binary()}
        }

  defstruct raw: nil, type: RRType.new(43), rdlength: nil, data: nil

  @spec new({integer(), integer(), integer(), binary()}) :: t()
  def new({key_tag, algorithm, digest_type, digest}) do
    raw = <<key_tag::16, algorithm::8, digest_type::8, digest::binary>>

    %__MODULE__{
      raw: raw,
      data: {key_tag, algorithm, digest_type, digest},
      rdlength: byte_size(raw)
    }
  end

  @spec from_iodata(bitstring(), bitstring() | nil) :: t()
  def from_iodata(raw, _message \\ nil) do
    <<key_tag::16, algorithm::8, digest_type::8, digest::binary>> = raw

    %__MODULE__{
      raw: raw,
      data: {key_tag, algorithm, digest_type, digest},
      rdlength: byte_size(raw)
    }
  end

  defimpl DNS.Parameter, for: DNS.Message.Record.Data.DS do
    @impl true
    def to_iodata(%DNS.Message.Record.Data.DS{data: data}) do
      {key_tag, algorithm, digest_type, digest} = data
      size = 4 + byte_size(digest)
      <<size::16, key_tag::16, algorithm::8, digest_type::8, digest::binary>>
    end
  end

  defimpl String.Chars, for: DNS.Message.Record.Data.DS do
    def to_string(%DNS.Message.Record.Data.DS{data: data}) do
      {key_tag, algorithm, digest_type, digest} = data
      digest_hex = Base.encode16(digest, case: :lower)
      "#{key_tag} #{algorithm} #{digest_type} #{digest_hex}"
    end
  end
end
