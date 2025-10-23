defmodule DNS.Message.Record.Data.OPT do
  @moduledoc """
  DNS OPT Record (Type 41)

  The OPT pseudo-RR is used to implement EDNS0 (Extension Mechanisms for DNS).
  It doesn't carry DNS data but contains control information for DNS transactions.

  RFC 6891 defines the OPT record format:
  - NAME: MUST be 0 (root domain)
  - TYPE: 41 (OPT)
  - CLASS: requestor's UDP payload size
  - TTL: extended RCODE and flags
  - RDLEN: length of all RDATA
  - RDATA: EDNS0 options
  """
  alias DNS.Message.EDNS0
  alias DNS.ResourceRecordType, as: RRType

  @type t :: %__MODULE__{
          type: RRType.t(),
          rdlength: 0..65535,
          raw: bitstring(),
          data: EDNS0.t()
        }

  defstruct raw: nil, type: RRType.new(41), rdlength: nil, data: nil

  @spec new(EDNS0.t()) :: t()
  def new(edns0) do
    raw = DNS.to_iodata(edns0)

    %__MODULE__{
      raw: raw,
      data: edns0,
      rdlength: byte_size(raw)
    }
  end

  @spec from_iodata(bitstring(), bitstring() | nil) :: t()
  def from_iodata(raw, _message \\ nil) do
    edns0 = EDNS0.from_iodata(raw)

    %__MODULE__{
      raw: raw,
      data: edns0,
      rdlength: byte_size(raw)
    }
  end

  defimpl DNS.Parameter, for: DNS.Message.Record.Data.OPT do
    @impl true
    def to_iodata(%DNS.Message.Record.Data.OPT{data: data}) do
      edns_binary = DNS.to_iodata(data)
      <<byte_size(edns_binary)::16, edns_binary::binary>>
    end
  end

  defimpl String.Chars, for: DNS.Message.Record.Data.OPT do
    def to_string(%DNS.Message.Record.Data.OPT{data: data}) do
      "#{data}"
    end
  end
end
