defmodule DNS.Message.Record.Data.TLSA do
  @moduledoc """
  DNS TLSA Record (Type 52)

  The TLSA record is used to associate a TLS server certificate or public key
  with the domain name where the record is found, using DNSSEC for authenticity.

  RFC 6698 defines the TLSA record format:
  - Usage: 1 octet
  - Selector: 1 octet
  - Matching Type: 1 octet
  - Certificate Association Data: variable length
  """
  alias DNS.ResourceRecordType, as: RRType

  @type t :: %__MODULE__{
          type: RRType.t(),
          rdlength: 0..65535,
          raw: bitstring(),
          data:
            {usage :: 0..255, selector :: 0..255, matching_type :: 0..255, cert_data :: binary()}
        }

  defstruct raw: nil, type: RRType.new(52), rdlength: nil, data: nil

  @spec new({integer(), integer(), integer(), binary()}) :: t()
  def new({usage, selector, matching_type, cert_data}) do
    raw = <<usage::8, selector::8, matching_type::8, cert_data::binary>>

    %__MODULE__{
      raw: raw,
      data: {usage, selector, matching_type, cert_data},
      rdlength: byte_size(raw)
    }
  end

  @spec from_iodata(bitstring(), bitstring() | nil) :: t()
  def from_iodata(raw, _message \\ nil) do
    <<usage::8, selector::8, matching_type::8, cert_data::binary>> = raw

    %__MODULE__{
      raw: raw,
      data: {usage, selector, matching_type, cert_data},
      rdlength: byte_size(raw)
    }
  end

  defimpl DNS.Parameter, for: DNS.Message.Record.Data.TLSA do
    @impl true
    def to_iodata(%DNS.Message.Record.Data.TLSA{data: data}) do
      {usage, selector, matching_type, cert_data} = data
      size = 3 + byte_size(cert_data)
      <<size::16, usage::8, selector::8, matching_type::8, cert_data::binary>>
    end
  end

  defimpl String.Chars, for: DNS.Message.Record.Data.TLSA do
    def to_string(%DNS.Message.Record.Data.TLSA{data: data}) do
      {usage, selector, matching_type, cert_data} = data
      cert_hex = Base.encode16(cert_data, case: :lower)
      "#{usage} #{selector} #{matching_type} #{cert_hex}"
    end
  end
end
