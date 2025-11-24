defmodule DNS.Message.EDNS0.Option.ECS do
  @moduledoc """
  EDNS0.Option.ECS [RFC7871](https://datatracker.ietf.org/doc/html/rfc7871)

  Option Format

   This protocol uses an EDNS0 [RFC6891] option to include client
   address information in DNS messages.  The option is structured as
   follows:

                    +0 (MSB)                            +1 (LSB)
          +---+---+---+---+---+---+---+---+---+---+---+---+---+---+---+---+
      0: |                          OPTION-CODE                          |
          +---+---+---+---+---+---+---+---+---+---+---+---+---+---+---+---+
      2: |                         OPTION-LENGTH                         |
          +---+---+---+---+---+---+---+---+---+---+---+---+---+---+---+---+
      4: |                            FAMILY                             |
          +---+---+---+---+---+---+---+---+---+---+---+---+---+---+---+---+
      6: |     SOURCE PREFIX-LENGTH      |     SCOPE PREFIX-LENGTH       |
          +---+---+---+---+---+---+---+---+---+---+---+---+---+---+---+---+
      8: |                           ADDRESS...                          /
          +---+---+---+---+---+---+---+---+---+---+---+---+---+---+---+---+

   o  (Defined in [RFC6891]) OPTION-CODE, 2 octets, for ECS is 8 (0x00
      0x08).

   o  (Defined in [RFC6891]) OPTION-LENGTH, 2 octets, contains the
      length of the payload (everything after OPTION-LENGTH) in octets.

   o  FAMILY, 2 octets, indicates the family of the address contained in
      the option, using address family codes as assigned by IANA in
      Address Family Numbers [Address_Family_Numbers].

   The format of the address part depends on the value of FAMILY.  This
   document only defines the format for FAMILY 1 (IPv4) and FAMILY 2
   (IPv6), which are as follows:

   o  SOURCE PREFIX-LENGTH, an unsigned octet representing the leftmost
      number of significant bits of ADDRESS to be used for the lookup.
      In responses, it mirrors the same value as in the queries.

   o  SCOPE PREFIX-LENGTH, an unsigned octet representing the leftmost
      number of significant bits of ADDRESS that the response covers.
      In queries, it MUST be set to 0.

   o  ADDRESS, variable number of octets, contains either an IPv4 or
      IPv6 address, depending on FAMILY, which MUST be truncated to the
      number of bits indicated by the SOURCE PREFIX-LENGTH field,
      padding with 0 bits to pad to the end of the last octet needed.

   o  A server receiving an ECS option that uses either too few or too
      many ADDRESS octets, or that has non-zero ADDRESS bits set beyond
      SOURCE PREFIX-LENGTH, SHOULD return FORMERR to reject the packet,
      as a signal to the software developer making the request to fix
      their implementation.

   All fields are in network byte order ("big-endian", per [RFC1700],
   Data Notation).


  """
  alias DNS.Message.EDNS0.OptionCode

  @type t :: %__MODULE__{
          code: OptionCode.t(),
          length: 0..65535,
          data:
            {client_subnet :: :inet.ip_address(), source_prefix :: 0..128, scope_prefix :: 0..128}
        }

  defstruct code: OptionCode.new(8), length: nil, data: nil

  @spec new({:inet.ip4_address(), 0..32, 0..32}) :: t()
  @spec new({:inet.ip6_address(), 0..128, 0..128}) :: t()
  def new({client_subnet, source_prefix, scope_prefix}) do
    raw = to_raw({client_subnet, source_prefix, scope_prefix})
    len = byte_size(raw)
    %__MODULE__{length: len, data: {client_subnet, source_prefix, scope_prefix}}
  end

  def from_iodata(<<8::16, length::16, payload::binary-size(length)>>) do
    {client_subnet, source_prefix, scope_prefix} = parse_raw(payload)

    %__MODULE__{length: length, data: {client_subnet, source_prefix, scope_prefix}}
  end

  defp parse_raw(<<family::16, source_prefix::8, scope_prefix::8, addr::binary>>) do
    case {family, source_prefix} do
      {1, source_prefix} when source_prefix in 0..8 ->
        <<a::8>> = addr
        {{a, 0, 0, 0}, source_prefix, scope_prefix}

      {1, source_prefix} when source_prefix in 9..16 ->
        <<a::8, b::8>> = addr
        {{a, b, 0, 0}, source_prefix, scope_prefix}

      {1, source_prefix} when source_prefix in 17..24 ->
        <<a::8, b::8, c::8>> = addr
        {{a, b, c, 0}, source_prefix, scope_prefix}

      {1, source_prefix} when source_prefix in 25..32 ->
        <<a::8, b::8, c::8, d::8>> = addr
        {{a, b, c, d}, source_prefix, scope_prefix}

      {2, source_prefix} when source_prefix in 0..8 ->
        <<a::8>> = addr

        {{Bitwise.<<<(a, 8), 0, 0, 0, 0, 0, 0, 0}, source_prefix, scope_prefix}

      {2, source_prefix} when source_prefix in 9..16 ->
        <<a::16>> = addr

        {{a, 0, 0, 0, 0, 0, 0, 0}, source_prefix, scope_prefix}

      {2, source_prefix} when source_prefix in 17..24 ->
        <<a::16, b::8>> = addr

        {{a, Bitwise.<<<(b, 8), 0, 0, 0, 0, 0, 0}, source_prefix, scope_prefix}

      {2, source_prefix} when source_prefix in 25..32 ->
        <<a::16, b::16>> = addr

        {{a, b, 0, 0, 0, 0, 0, 0}, source_prefix, scope_prefix}

      {2, source_prefix} when source_prefix in 33..40 ->
        <<a::16, b::16, c::8>> = addr

        {{a, b, Bitwise.<<<(c, 8), 0, 0, 0, 0, 0}, source_prefix, scope_prefix}

      {2, source_prefix} when source_prefix in 41..48 ->
        <<a::16, b::16, c::16>> = addr

        {{a, b, c, 0, 0, 0, 0, 0}, source_prefix, scope_prefix}

      {2, source_prefix} when source_prefix in 49..56 ->
        <<a::16, b::16, c::16, d::8>> = addr

        {{a, b, c, Bitwise.<<<(d, 8), 0, 0, 0, 0}, source_prefix, scope_prefix}

      {2, source_prefix} when source_prefix in 57..64 ->
        <<a::16, b::16, c::16, d::16>> = addr

        {{a, b, c, d, 0, 0, 0, 0}, source_prefix, scope_prefix}

      {2, source_prefix} when source_prefix in 65..72 ->
        <<a::16, b::16, c::16, d::16, e::8>> = addr

        {{a, b, c, d, Bitwise.<<<(e, 8), 0, 0, 0}, source_prefix, scope_prefix}

      {2, source_prefix} when source_prefix <= 80 ->
        <<a::16, b::16, c::16, d::16, e::16>> = addr

        {{a, b, c, d, e, 0, 0, 0}, source_prefix, scope_prefix}

      {2, source_prefix} when source_prefix <= 88 ->
        <<a::16, b::16, c::16, d::16, e::16, f::8>> = addr

        {{a, b, c, d, e, Bitwise.<<<(f, 8), 0, 0}, source_prefix, scope_prefix}

      {2, source_prefix} when source_prefix <= 96 ->
        <<a::16, b::16, c::16, d::16, e::16, f::16>> = addr

        {{a, b, c, d, e, f, 0, 0}, source_prefix, scope_prefix}

      {2, source_prefix} when source_prefix <= 104 ->
        <<a::16, b::16, c::16, d::16, e::16, f::16, g::8>> = addr

        {{a, b, c, d, e, f, Bitwise.<<<(g, 8), 0}, source_prefix, scope_prefix}

      {2, source_prefix} when source_prefix <= 112 ->
        <<a::16, b::16, c::16, d::16, e::16, f::16, g::16>> = addr

        {{a, b, c, d, e, f, g, 0}, source_prefix, scope_prefix}

      {2, source_prefix} when source_prefix <= 120 ->
        <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::8>> = addr

        {{a, b, c, d, e, f, g, Bitwise.<<<(h, 8)}, source_prefix, scope_prefix}

      {2, source_prefix} when source_prefix <= 128 ->
        <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>> = addr

        {{a, b, c, d, e, f, g, h}, source_prefix, scope_prefix}
    end
  end

  @spec to_raw({:inet.ip4_address(), 0..32, 0..32}) :: binary()
  @spec to_raw({:inet.ip6_address(), 0..128, 0..128}) :: binary()
  def to_raw({client_subnet, source_prefix, scope_prefix}) do
    {family, addr} =
      if :inet.is_ipv4_address(client_subnet) do
        {a, b, c, d} = client_subnet

        case source_prefix do
          s when s in 0..8 ->
            {1, <<a::8>>}

          s when s in 9..16 ->
            {1, <<a::8, b::8>>}

          s when s in 17..24 ->
            {1, <<a::8, b::8, c::8>>}

          s when s in 25..32 ->
            {1, <<a::8, b::8, c::8, d::8>>}
        end
      else
        {a, b, c, d, e, f, g, h} = client_subnet

        case source_prefix do
          s when s in 0..8 ->
            {2, <<Bitwise.>>>(a, 8)::8>>}

          s when s in 9..16 ->
            {2, <<a::16>>}

          s when s in 17..24 ->
            {2, <<a::16, Bitwise.>>>(b, 8)::8>>}

          s when s in 25..32 ->
            {2, <<a::16, b::16>>}

          s when s in 33..40 ->
            {2, <<a::16, b::16, Bitwise.>>>(c, 8)::8>>}

          s when s in 41..48 ->
            {2, <<a::16, b::16, c::16>>}

          s when s in 49..56 ->
            {2, <<a::16, b::16, c::16, Bitwise.>>>(d, 8)::8>>}

          s when s in 57..64 ->
            {2, <<a::16, b::16, c::16, d::16>>}

          s when s in 65..72 ->
            {2, <<a::16, b::16, c::16, d::16, Bitwise.>>>(e, 8)::8>>}

          s when s in 73..80 ->
            {2, <<a::16, b::16, c::16, d::16, e::16>>}

          s when s in 81..88 ->
            {2, <<a::16, b::16, c::16, d::16, e::16, Bitwise.>>>(f, 8)::8>>}

          s when s in 89..96 ->
            {2, <<a::16, b::16, c::16, d::16, e::16, f::16>>}

          s when s in 97..104 ->
            {2, <<a::16, b::16, c::16, d::16, e::16, f::16, Bitwise.>>>(g, 8)::8>>}

          s when s in 105..112 ->
            {2, <<a::16, b::16, c::16, d::16, e::16, f::16, g::16>>}

          s when s in 113..120 ->
            {2, <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, Bitwise.>>>(h, 8)::8>>}

          s when s in 121..128 ->
            {2, <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>>}
        end
      end

    <<family::16, source_prefix::8, scope_prefix::8, addr::binary>>
  end

  defimpl DNS.Parameter, for: DNS.Message.EDNS0.Option.ECS do
    @impl true
    def to_iodata(%DNS.Message.EDNS0.Option.ECS{
          data: {client_subnet, source_prefix, scope_prefix}
        }) do
      raw = DNS.Message.EDNS0.Option.ECS.to_raw({client_subnet, source_prefix, scope_prefix})
      <<8::16, byte_size(raw)::16, raw::binary>>
    end
  end

  defimpl String.Chars, for: DNS.Message.EDNS0.Option.ECS do
    def to_string(%DNS.Message.EDNS0.Option.ECS{
          code: code,
          data: {client_subnet, source_prefix, scope_prefix}
        }) do
      "#{code}: #{:inet.ntoa(client_subnet)}/#{source_prefix}/#{scope_prefix}"
    end
  end
end
