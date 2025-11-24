defmodule DNS.Message.Record.Data.NSEC3PARAM do
  @moduledoc """
  DNS NSEC3PARAM Record (Type 51)

  The NSEC3PARAM record provides parameters needed by authoritative servers
  to calculate hashed owner names for NSEC3 records.

  RFC 5155 defines the NSEC3PARAM record format:
  - Hash Algorithm: 1 octet
  - Flags: 1 octet
  - Iterations: 2 octets
  - Salt Length: 1 octet
  - Salt: variable length
  """
  alias DNS.ResourceRecordType, as: RRType

  @type t :: %__MODULE__{
          type: RRType.t(),
          rdlength: 0..65535,
          raw: bitstring(),
          data: {
            hash_algorithm :: 0..255,
            flags :: 0..255,
            iterations :: 0..65535,
            salt :: binary()
          }
        }

  defstruct raw: nil, type: RRType.new(51), rdlength: nil, data: nil

  @spec new({integer(), integer(), integer(), binary()}) :: t()
  def new({hash_algorithm, flags, iterations, salt}) do
    salt_length = byte_size(salt)

    raw = <<
      hash_algorithm::8,
      flags::8,
      iterations::16,
      salt_length::8,
      salt::binary
    >>

    %__MODULE__{
      raw: raw,
      data: {hash_algorithm, flags, iterations, salt},
      rdlength: byte_size(raw)
    }
  end

  @spec from_iodata(bitstring(), bitstring() | nil) :: t()
  def from_iodata(raw, _message \\ nil) do
    <<
      hash_algorithm::8,
      flags::8,
      iterations::16,
      salt_length::8,
      salt::binary-size(salt_length)
    >> = raw

    %__MODULE__{
      raw: raw,
      data: {hash_algorithm, flags, iterations, salt},
      rdlength: byte_size(raw)
    }
  end

  defimpl DNS.Parameter, for: DNS.Message.Record.Data.NSEC3PARAM do
    @impl true
    def to_iodata(%DNS.Message.Record.Data.NSEC3PARAM{data: data}) do
      {hash_algorithm, flags, iterations, salt} = data

      salt_length = byte_size(salt)
      size = 1 + 1 + 2 + 1 + salt_length

      <<
        size::16,
        hash_algorithm::8,
        flags::8,
        iterations::16,
        salt_length::8,
        salt::binary
      >>
    end
  end

  defimpl String.Chars, for: DNS.Message.Record.Data.NSEC3PARAM do
    def to_string(%DNS.Message.Record.Data.NSEC3PARAM{data: data}) do
      {hash_algorithm, flags, iterations, salt} = data
      salt_hex = Base.encode16(salt, case: :lower)
      "#{hash_algorithm} #{flags} #{iterations} #{salt_hex}"
    end
  end
end
