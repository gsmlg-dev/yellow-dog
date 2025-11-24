defmodule DNS.Message.Record.Data.RRSIG do
  @moduledoc """
  DNS RRSIG Record (Type 46)

  The RRSIG record contains a digital signature for a set of resource records
  in DNSSEC. It is used to verify the authenticity and integrity of DNS data.

  RFC 4034 defines the RRSIG record format:
  - Type Covered: 2 octets (RR type being signed)
  - Algorithm: 1 octet
  - Labels: 1 octet
  - Original TTL: 4 octets
  - Signature Expiration: 4 octets
  - Signature Inception: 4 octets
  - Key Tag: 2 octets
  - Signer's Name: domain name
  - Signature: variable length (base64 encoded)
  """
  alias DNS.Message.Domain
  alias DNS.ResourceRecordType, as: RRType

  @type t :: %__MODULE__{
          type: RRType.t(),
          rdlength: 0..65535,
          raw: bitstring(),
          data: {
            type_covered :: RRType.t(),
            algorithm :: 0..255,
            labels :: 0..255,
            original_ttl :: 0..4_294_967_295,
            signature_expiration :: 0..4_294_967_295,
            signature_inception :: 0..4_294_967_295,
            key_tag :: 0..65535,
            signers_name :: Domain.t(),
            signature :: binary()
          }
        }

  defstruct raw: nil, type: RRType.new(46), rdlength: nil, data: nil

  @spec new(
          {RRType.t(), integer(), integer(), integer(), integer(), integer(), integer(),
           Domain.t(), binary()}
        ) :: t()
  def new(
        {type_covered, algorithm, labels, original_ttl, signature_expiration, signature_inception,
         key_tag, signers_name, signature}
      ) do
    type_covered_binary = DNS.to_iodata(type_covered)
    signers_name_binary = DNS.to_iodata(signers_name)

    raw = <<
      type_covered_binary::binary,
      algorithm::8,
      labels::8,
      original_ttl::32,
      signature_expiration::32,
      signature_inception::32,
      key_tag::16,
      signers_name_binary::binary,
      signature::binary
    >>

    %__MODULE__{
      raw: raw,
      data:
        {type_covered, algorithm, labels, original_ttl, signature_expiration, signature_inception,
         key_tag, signers_name, signature},
      rdlength: byte_size(raw)
    }
  end

  @spec from_iodata(bitstring(), bitstring() | nil) :: t()
  def from_iodata(raw, message \\ nil) do
    <<type_covered::16, algorithm::8, labels::8, original_ttl::32, signature_expiration::32,
      signature_inception::32, key_tag::16, rest::binary>> = raw

    signers_name = Domain.from_iodata(rest, message)
    signature_start = signers_name.size
    signature = binary_part(rest, signature_start, byte_size(rest) - signature_start)

    %__MODULE__{
      raw: raw,
      data: {
        RRType.new(type_covered),
        algorithm,
        labels,
        original_ttl,
        signature_expiration,
        signature_inception,
        key_tag,
        signers_name,
        signature
      },
      rdlength: byte_size(raw)
    }
  end

  defimpl DNS.Parameter, for: DNS.Message.Record.Data.RRSIG do
    @impl true
    def to_iodata(%DNS.Message.Record.Data.RRSIG{data: data}) do
      {type_covered, algorithm, labels, original_ttl, signature_expiration, signature_inception,
       key_tag, signers_name, signature} = data

      type_covered_binary = DNS.to_iodata(type_covered)
      signers_name_binary = DNS.to_iodata(signers_name)
      size = 2 + 1 + 1 + 4 + 4 + 4 + 2 + byte_size(signers_name_binary) + byte_size(signature)

      <<
        size::16,
        type_covered_binary::binary,
        algorithm::8,
        labels::8,
        original_ttl::32,
        signature_expiration::32,
        signature_inception::32,
        key_tag::16,
        signers_name_binary::binary,
        signature::binary
      >>
    end
  end

  defimpl String.Chars, for: DNS.Message.Record.Data.RRSIG do
    def to_string(%DNS.Message.Record.Data.RRSIG{data: data}) do
      {type_covered, algorithm, labels, original_ttl, signature_expiration, signature_inception,
       key_tag, signers_name, signature} = data

      signature_b64 = Base.encode64(signature)

      "#{type_covered} #{algorithm} #{labels} #{original_ttl} #{signature_expiration} #{signature_inception} #{key_tag} #{signers_name} #{signature_b64}"
    end
  end
end
