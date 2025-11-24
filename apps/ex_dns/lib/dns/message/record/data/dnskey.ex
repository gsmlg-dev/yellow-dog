defmodule DNS.Message.Record.Data.DNSKEY do
  @moduledoc """
  DNS DNSKEY Record (Type 48)

  The DNSKEY record contains a public key used in DNSSEC to verify signatures.
  It is used to authenticate records in DNSSEC-signed zones.

  RFC 4034 defines the DNSKEY record format:
  - Flags: 2 octets
  - Protocol: 1 octet (must be 3 for DNSSEC)
  - Algorithm: 1 octet
  - Public Key: variable length (base64 encoded)
  """
  alias DNS.ResourceRecordType, as: RRType

  @type t :: %__MODULE__{
          type: RRType.t(),
          rdlength: 0..65535,
          raw: bitstring(),
          data:
            {flags :: 0..65535, protocol :: 0..255, algorithm :: 0..255, public_key :: binary()}
        }

  defstruct raw: nil, type: RRType.new(48), rdlength: nil, data: nil

  @spec new({integer(), integer(), integer(), binary()}) :: t()
  def new({flags, protocol, algorithm, public_key}) do
    raw = <<flags::16, protocol::8, algorithm::8, public_key::binary>>

    %__MODULE__{
      raw: raw,
      data: {flags, protocol, algorithm, public_key},
      rdlength: byte_size(raw)
    }
  end

  @spec from_iodata(bitstring(), bitstring() | nil) :: t()
  def from_iodata(raw, _message \\ nil) do
    <<flags::16, protocol::8, algorithm::8, public_key::binary>> = raw

    %__MODULE__{
      raw: raw,
      data: {flags, protocol, algorithm, public_key},
      rdlength: byte_size(raw)
    }
  end

  defimpl DNS.Parameter, for: DNS.Message.Record.Data.DNSKEY do
    @impl true
    def to_iodata(%DNS.Message.Record.Data.DNSKEY{data: data}) do
      {flags, protocol, algorithm, public_key} = data
      size = 4 + byte_size(public_key)
      <<size::16, flags::16, protocol::8, algorithm::8, public_key::binary>>
    end
  end

  defimpl String.Chars, for: DNS.Message.Record.Data.DNSKEY do
    def to_string(%DNS.Message.Record.Data.DNSKEY{data: data}) do
      {flags, protocol, algorithm, public_key} = data
      public_key_b64 = Base.encode64(public_key)
      "#{flags} #{protocol} #{algorithm} #{public_key_b64}"
    end
  end
end
