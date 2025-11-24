defmodule DNS.Message.Record.Data.NSEC3 do
  @moduledoc """
  DNS NSEC3 Record (Type 50)

  The NSEC3 record provides authenticated denial of existence for DNSSEC,
  using hashed owner names instead of the original NSEC approach.

  RFC 5155 defines the NSEC3 record format:
  - Hash Algorithm: 1 octet
  - Flags: 1 octet
  - Iterations: 2 octets
  - Salt Length: 1 octet
  - Salt: variable length
  - Hash Length: 1 octet
  - Next Hashed Owner Name: variable length
  - Type Bit Maps: variable length
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
            salt :: binary(),
            next_hashed_owner_name :: binary(),
            type_bit_maps :: binary()
          }
        }

  defstruct raw: nil, type: RRType.new(50), rdlength: nil, data: nil

  @spec new({integer(), integer(), integer(), binary(), binary(), binary()}) :: t()
  def new({hash_algorithm, flags, iterations, salt, next_hashed_owner_name, type_bit_maps}) do
    salt_length = byte_size(salt)
    hash_length = byte_size(next_hashed_owner_name)

    raw = <<
      hash_algorithm::8,
      flags::8,
      iterations::16,
      salt_length::8,
      salt::binary,
      hash_length::8,
      next_hashed_owner_name::binary,
      type_bit_maps::binary
    >>

    %__MODULE__{
      raw: raw,
      data: {hash_algorithm, flags, iterations, salt, next_hashed_owner_name, type_bit_maps},
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
      salt::binary-size(salt_length),
      hash_length::8,
      next_hashed_owner_name::binary-size(hash_length),
      type_bit_maps::binary
    >> = raw

    %__MODULE__{
      raw: raw,
      data: {hash_algorithm, flags, iterations, salt, next_hashed_owner_name, type_bit_maps},
      rdlength: byte_size(raw)
    }
  end

  defimpl DNS.Parameter, for: DNS.Message.Record.Data.NSEC3 do
    @impl true
    def to_iodata(%DNS.Message.Record.Data.NSEC3{data: data}) do
      {hash_algorithm, flags, iterations, salt, next_hashed_owner_name, type_bit_maps} = data

      salt_length = byte_size(salt)
      hash_length = byte_size(next_hashed_owner_name)
      size = 1 + 1 + 2 + 1 + salt_length + 1 + hash_length + byte_size(type_bit_maps)

      <<
        size::16,
        hash_algorithm::8,
        flags::8,
        iterations::16,
        salt_length::8,
        salt::binary,
        hash_length::8,
        next_hashed_owner_name::binary,
        type_bit_maps::binary
      >>
    end
  end

  defimpl String.Chars, for: DNS.Message.Record.Data.NSEC3 do
    def to_string(%DNS.Message.Record.Data.NSEC3{data: data}) do
      {hash_algorithm, flags, iterations, salt, next_hashed_owner_name, _type_bit_maps} = data
      salt_hex = Base.encode16(salt, case: :lower)
      next_hex = Base.encode16(next_hashed_owner_name, case: :lower)
      "#{hash_algorithm} #{flags} #{iterations} #{salt_hex} #{next_hex}"
    end
  end
end
