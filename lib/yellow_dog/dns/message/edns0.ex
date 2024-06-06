defmodule YellowDog.DNS.Message.EDNS0 do
  @moduledoc """
  # EDNS0 moudle
  EDNS0 is defined in [RFC6891](https://datatracker.ietf.org/doc/html/rfc6891)

  When Message additional section includes a record with type 41,
  it is the OPT pseudo-RR, which includes EDNS0 information.

  An OPT pseudo-RR (sometimes called a meta-RR) MAY be added to the
  additional data section of a request.

  The OPT RR has RR type 41.

  If an OPT record is present in a received request, compliant
  responders MUST include an OPT record in their respective responses.

  An OPT record does not carry any DNS data.  It is used only to
  contain control information pertaining to the question-and-answer
  sequence of a specific transaction.  OPT RRs MUST NOT be cached,
  forwarded, or stored in or loaded from master files.

  The OPT RR MAY be placed anywhere within the additional data section.
  When an OPT RR is included within any DNS message, it MUST be the
  only OPT RR in that message.  If a query message with more than one
  OPT RR is received, a FORMERR (RCODE=1) MUST be returned.  The
  placement flexibility for the OPT RR does not override the need for
  the TSIG or SIG(0) RRs to be the last in the additional section
  whenever they are present.

  The fixed part of an OPT RR is structured as follows:

       +------------+--------------+------------------------------+
       | Field Name | Field Type   | Description                  |
       +------------+--------------+------------------------------+
       | NAME       | domain name  | MUST be 0 (root domain)      |
       | TYPE       | u_int16_t    | OPT (41)                     |
       | CLASS      | u_int16_t    | requestor's UDP payload size |
       | TTL        | u_int32_t    | extended RCODE and flags     |
       | RDLEN      | u_int16_t    | length of all RDATA          |
       | RDATA      | octet stream | {attribute,value} pairs      |
       +------------+--------------+------------------------------+

  The extended RCODE and flags, which OPT stores in the RR Time to Live
  (TTL) field, are structured as follows:

                      +0 (MSB)                            +1 (LSB)
          +---+---+---+---+---+---+---+---+---+---+---+---+---+---+---+---+
       0: |         EXTENDED-RCODE        |            VERSION            |
          +---+---+---+---+---+---+---+---+---+---+---+---+---+---+---+---+
       2: | DO|                           Z                               |
          +---+---+---+---+---+---+---+---+---+---+---+---+---+---+---+---+

  ## EXTENDED-RCODE

  Forms the upper 8 bits of extended 12-bit RCODE (together with the
  4 bits defined in [RFC1035].  Note that EXTENDED-RCODE value 0
  indicates that an unextended RCODE is in use (values 0 through
  15).

  ## VERSION

  Indicates the implementation level of the setter.  Full
  conformance with this specification is indicated by version '0'.
  Requestors are encouraged to set this to the lowest implemented
  level capable of expressing a transaction, to minimise the
  responder and network load of discovering the greatest common
  implementation level between requestor and responder.  A
  requestor's version numbering strategy MAY ideally be a run-time
  configuration option.

  If a responder does not implement the VERSION level of the
  request, then it MUST respond with RCODE=BADVERS.  All responses
  MUST be limited in format to the VERSION level of the request, but
  the VERSION of each response SHOULD be the highest implementation
  level of the responder.  In this way, a requestor will learn the
  implementation level of a responder as a side effect of every
  response, including error responses and including RCODE=BADVERS.

  ## DO

  DNSSEC OK bit as defined by [RFC3225].

  ## Z

  Set to zero by senders and ignored by receivers, unless modified
  in a subsequent specification.

  The variable part of an OPT RR may contain zero or more options in
  the RDATA.  Each option MUST be treated as a bit field.  Each option
  is encoded as:

                      +0 (MSB)                            +1 (LSB)
          +---+---+---+---+---+---+---+---+---+---+---+---+---+---+---+---+
       0: |                          OPTION-CODE                          |
          +---+---+---+---+---+---+---+---+---+---+---+---+---+---+---+---+
       2: |                         OPTION-LENGTH                         |
          +---+---+---+---+---+---+---+---+---+---+---+---+---+---+---+---+
       4: |                                                               |
          /                          OPTION-DATA                          /
          /                                                               /
          +---+---+---+---+---+---+---+---+---+---+---+---+---+---+---+---+

  ## OPTION-CODE

  Assigned by the Expert Review process as defined by the DNSEXT
  working group and the IESG.

  ## OPTION-LENGTH

  Size (in octets) of OPTION-DATA.

  ## OPTION-DATA

  Varies per OPTION-CODE.  MUST be treated as a bit field.

  The order of appearance of option tuples is not defined.  If one
  option modifies the behaviour of another or multiple options are
  related to one another in some way, they have the same effect
  regardless of ordering in the RDATA wire encoding.

  Any OPTION-CODE values not understood by a responder or requestor
  MUST be ignored.  Specifications of such options might wish to
  include some kind of signaled acknowledgement.  For example, an
  option specification might say that if a responder sees and supports
  option XYZ, it MUST include option XYZ in its response.

  """

  # alias YellowDog.DNS.Message
  alias YellowDog.DNS.Message.EDNS0
  # alias YellowDog.DNS.Message.Record
  # alias YellowDog.DNS.ResourceRecord.Type, as: RType
  alias YellowDog.DNS.Message.EDNS0.Option

  @type t :: %__MODULE__{
          udp_payload: integer(),
          extended_rcode: integer(),
          version: integer(),
          do_bit: integer(),
          flags: integer(),
          options: []
        }

  defstruct udp_payload: 0,
            extended_rcode: 0,
            version: 0,
            do_bit: 0,
            flags: 0,
            options: []

  def from_buffer(
        <<0::8, 41::16, udp_payload::16, extended_rcode::8, version::8, do_bit::1, flags::15,
          rdlenght::16, rdata::binary>>
      ) do
    %EDNS0{
      udp_payload: udp_payload,
      extended_rcode: extended_rcode,
      version: version,
      do_bit: do_bit,
      flags: flags,
      options: parse_rdata(rdlenght, rdata)
    }
  end

  @doc """
  Converts a Record struct to binary data.
  """
  def to_buffer(edns0 = %__MODULE__{}) do
    <<0::8, 41::16, edns0.udp_payload::16, edns0.extended_rcode::8, edns0.version::8,
      edns0.do_bit::1, edns0.flags::15, encode_options(edns0.options)::binary>>
  end

  def new() do
    %__MODULE__{
      udp_payload: 0,
      extended_rcode: 0,
      version: 0,
      do_bit: 0,
      flags: 0,
      options: []
    }
  end

  def is_opt(<<0::8, 41::16, _::binary>>), do: true
  def is_opt(_), do: false

  def add_option(edns0 = %__MODULE__{}, code, data) do
    %EDNS0{edns0 | options: [{code, data} | edns0.options]}
  end

  def to_print(edns0 = %__MODULE__{}) do
    opt_str = edns0.options |> Enum.map(fn opt -> Option.to_print(opt) end) |> Enum.join("\n")

    """
    ; EDNS: version: #{edns0.version}, flags: #{if(edns0.do_bit == 1, do: "DO")} udp: #{edns0.udp_payload}#{if(length(edns0.options) > 0, do: "\n#{opt_str}")}
    """
  end

  defp parse_rdata(rdlength, rdata) do
    with rdata_size <- byte_size(rdata),
         true <- rdlength == 0 or rdlength > 4,
         true <- rdata_size == rdlength do
      if rdlength > 0 do
        seek_option(rdata)
      else
        []
      end
    else
      e ->
        throw({:invalid_rdlength, e, rdlength, rdata})
    end
  end

  defp seek_option(data, options \\ [])

  defp seek_option(<<code::16, length::16, data::binary>>, options) do
    <<opt_data::binary-size(length), next_data::binary>> = data
    parsed_data = Option.parse(code, opt_data)
    options = [{code, parsed_data} | options]

    if byte_size(next_data) > 0 do
      seek_option(next_data, options)
    else
      options
    end
  end

  defp seek_option(_, _) do
    throw({:edns_option_error})
  end

  defp encode_options(options) do
    opt_binary =
      for {code, value} <- options do
        parsed_value = Option.encode(code, value)
        <<code::16, byte_size(parsed_value)::16, parsed_value::binary>>
      end
      |> Enum.join(<<>>)

    <<byte_size(opt_binary)::16, opt_binary::binary>>
  end

  defmodule Option do
    @moduledoc """
    DNS EDNS0 Option Codes (OPT)

          0	Reserved		[RFC6891](https://datatracker.ietf.org/doc/html/rfc6891)
          1	LLQ	Optional	[RFC8764](https://datatracker.ietf.org/doc/html/rfc8764)
          2	Update Lease	Standard	[RFC-ietf-dnssd-update-lease-08]
          3	NSID	Standard	[RFC5001](https://datatracker.ietf.org/doc/html/rfc5001)
          4	Reserved		[draft-cheshire-edns0-owner-option]
          5	DAU	Standard	[RFC6975](https://datatracker.ietf.org/doc/html/rfc6975)
          6	DHU	Standard	[RFC6975](https://datatracker.ietf.org/doc/html/rfc6975)
          7	N3U	Standard	[RFC6975](https://datatracker.ietf.org/doc/html/rfc6975)
          8	edns-client-subnet	Optional	[RFC7871](https://datatracker.ietf.org/doc/html/rfc7871)
          9	EDNS EXPIRE	Optional	[RFC7314](https://datatracker.ietf.org/doc/html/rfc7314)
          10	COOKIE	Standard	[RFC7873](https://datatracker.ietf.org/doc/html/rfc7873)
          11	edns-tcp-keepalive	Standard	[RFC7828](https://datatracker.ietf.org/doc/html/rfc7828)
          12	Padding	Standard	[RFC7830](https://datatracker.ietf.org/doc/html/rfc7830)
          13	CHAIN	Standard	[RFC7901](https://datatracker.ietf.org/doc/html/rfc7901)
          14	edns-key-tag	Optional	[RFC8145](https://datatracker.ietf.org/doc/html/rfc8145)
          15	Extended DNS Error	Standard	[RFC8914](https://datatracker.ietf.org/doc/html/rfc8914)
          16	EDNS-Client-Tag	Optional	[draft-bellis-dnsop-edns-tags]
          17	EDNS-Server-Tag	Optional	[draft-bellis-dnsop-edns-tags]
          18	Report-Channel	Standard	[RFC9567](https://datatracker.ietf.org/doc/html/rfc9567)
          19-20291	Unassigned
          20292	Umbrella Ident	Optional	[https://developer.cisco.com/docs/cloud-security/#!integrating-network-devices/rdata-description][Cisco_CIE_DNS_team]
          20293-26945	Unassigned
          26946	DeviceID	Optional	[https://developer.cisco.com/docs/cloud-security/#!network-devices-getting-started/response-codes][Cisco_CIE_DNS_team]
          26947-65000	Unassigned
          65001-65534	Reserved for Local/Experimental Use		[RFC6891](https://datatracker.ietf.org/doc/html/rfc6891)
          65535	Reserved for future expansion		[RFC6891](https://datatracker.ietf.org/doc/html/rfc6891)
    """

    @doc """
    Parse Option

    ## 8	edns-client-subnet

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
    """
    def parse(code, buffer)

    def parse(8, <<family::16, source_prefix::8, scope_prefix::8, addr::binary>>) do
      case {family, source_prefix} do
        {1, source_prefix} when source_prefix <= 8 ->
          <<a::8>> = addr
          {{a, 0, 0, 0}, source_prefix, scope_prefix}

        {1, source_prefix} when source_prefix <= 16 ->
          <<a::8, b::8>> = addr
          {{a, b, 0, 0}, source_prefix, scope_prefix}

        {1, source_prefix} when source_prefix <= 24 ->
          <<a::8, b::8, c::8>> = addr
          {{a, b, c, 0}, source_prefix, scope_prefix}

        {1, source_prefix} when source_prefix <= 32 ->
          <<a::8, b::8, c::8, d::8>> = addr
          {{a, b, c, d}, source_prefix, scope_prefix}

        {2, source_prefix} when source_prefix <= 8 ->
          <<a::8>> = addr

          {{Bitwise.<<<(a, 8) |> Bitwise.bor(0), 0, 0, 0, 0, 0, 0, 0}, source_prefix,
           scope_prefix}

        {2, source_prefix} when source_prefix <= 16 ->
          <<a::8, b::8>> = addr

          {{Bitwise.<<<(a, 8) |> Bitwise.bor(b), 0, 0, 0, 0, 0, 0, 0}, source_prefix,
           scope_prefix}

        {2, source_prefix} when source_prefix <= 24 ->
          <<a::8, b::8, c::8>> = addr

          {{Bitwise.<<<(a, 8) |> Bitwise.bor(b), Bitwise.<<<(c, 8) |> Bitwise.bor(0), 0, 0, 0, 0,
            0, 0}, source_prefix, scope_prefix}

        {2, source_prefix} when source_prefix <= 32 ->
          <<a::8, b::8, c::8, d::8>> = addr

          {{Bitwise.<<<(a, 8) |> Bitwise.bor(b), Bitwise.<<<(c, 8) |> Bitwise.bor(d), 0, 0, 0, 0,
            0, 0}, source_prefix, scope_prefix}

        {2, source_prefix} when source_prefix <= 40 ->
          <<a::8, b::8, c::8, d::8, e::8>> = addr

          {{Bitwise.<<<(a, 8) |> Bitwise.bor(b), Bitwise.<<<(c, 8) |> Bitwise.bor(d),
            Bitwise.<<<(e, 8) |> Bitwise.bor(0), 0, 0, 0, 0, 0}, source_prefix, scope_prefix}

        {2, source_prefix} when source_prefix <= 48 ->
          <<a::8, b::8, c::8, d::8, e::8, f::8>> = addr

          {{Bitwise.<<<(a, 8) |> Bitwise.bor(b), Bitwise.<<<(c, 8) |> Bitwise.bor(d),
            Bitwise.<<<(e, 8) |> Bitwise.bor(f), 0, 0, 0, 0, 0}, source_prefix, scope_prefix}

        {2, source_prefix} when source_prefix <= 56 ->
          <<a::8, b::8, c::8, d::8, e::8, f::8, g::8>> = addr

          {{Bitwise.<<<(a, 8) |> Bitwise.bor(b), Bitwise.<<<(c, 8) |> Bitwise.bor(d),
            Bitwise.<<<(e, 8) |> Bitwise.bor(f), Bitwise.<<<(g, 8) |> Bitwise.bor(0), 0, 0, 0, 0},
           source_prefix, scope_prefix}

        {2, source_prefix} when source_prefix <= 64 ->
          <<a::8, b::8, c::8, d::8, e::8, f::8, g::8, h::8>> = addr

          {{Bitwise.<<<(a, 8) |> Bitwise.bor(b), Bitwise.<<<(c, 8) |> Bitwise.bor(d),
            Bitwise.<<<(e, 8) |> Bitwise.bor(f), Bitwise.<<<(g, 8) |> Bitwise.bor(h), 0, 0, 0, 0},
           source_prefix, scope_prefix}

        {2, source_prefix} when source_prefix <= 72 ->
          <<a::8, b::8, c::8, d::8, e::8, f::8, g::8, h::8, i::8>> =
            addr

          {{Bitwise.<<<(a, 8) |> Bitwise.bor(b), Bitwise.<<<(c, 8) |> Bitwise.bor(d),
            Bitwise.<<<(e, 8) |> Bitwise.bor(f), Bitwise.<<<(g, 8) |> Bitwise.bor(h),
            Bitwise.<<<(i, 8) |> Bitwise.bor(0), 0, 0, 0}, source_prefix, scope_prefix}

        {2, source_prefix} when source_prefix <= 80 ->
          <<a::8, b::8, c::8, d::8, e::8, f::8, g::8, h::8, i::8, j::8>> =
            addr

          {{Bitwise.<<<(a, 8) |> Bitwise.bor(b), Bitwise.<<<(c, 8) |> Bitwise.bor(d),
            Bitwise.<<<(e, 8) |> Bitwise.bor(f), Bitwise.<<<(g, 8) |> Bitwise.bor(h),
            Bitwise.<<<(i, 8) |> Bitwise.bor(j), 0, 0, 0}, source_prefix, scope_prefix}

        {2, source_prefix} when source_prefix <= 88 ->
          <<a::8, b::8, c::8, d::8, e::8, f::8, g::8, h::8, i::8, j::8, k::8>> =
            addr

          {{Bitwise.<<<(a, 8) |> Bitwise.bor(b), Bitwise.<<<(c, 8) |> Bitwise.bor(d),
            Bitwise.<<<(e, 8) |> Bitwise.bor(f), Bitwise.<<<(g, 8) |> Bitwise.bor(h),
            Bitwise.<<<(i, 8) |> Bitwise.bor(j), Bitwise.<<<(k, 8) |> Bitwise.bor(0), 0, 0},
           source_prefix, scope_prefix}

        {2, source_prefix} when source_prefix <= 96 ->
          <<a::8, b::8, c::8, d::8, e::8, f::8, g::8, h::8, i::8, j::8, k::8, l::8>> =
            addr

          {{Bitwise.<<<(a, 8) |> Bitwise.bor(b), Bitwise.<<<(c, 8) |> Bitwise.bor(d),
            Bitwise.<<<(e, 8) |> Bitwise.bor(f), Bitwise.<<<(g, 8) |> Bitwise.bor(h),
            Bitwise.<<<(i, 8) |> Bitwise.bor(j), Bitwise.<<<(k, 8) |> Bitwise.bor(l), 0, 0},
           source_prefix, scope_prefix}

        {2, source_prefix} when source_prefix <= 104 ->
          <<a::8, b::8, c::8, d::8, e::8, f::8, g::8, h::8, i::8, j::8, k::8, l::8, m::8>> =
            addr

          {{Bitwise.<<<(a, 8) |> Bitwise.bor(b), Bitwise.<<<(c, 8) |> Bitwise.bor(d),
            Bitwise.<<<(e, 8) |> Bitwise.bor(f), Bitwise.<<<(g, 8) |> Bitwise.bor(h),
            Bitwise.<<<(i, 8) |> Bitwise.bor(j), Bitwise.<<<(k, 8) |> Bitwise.bor(l),
            Bitwise.<<<(m, 8) |> Bitwise.bor(0), 0}, source_prefix, scope_prefix}

        {2, source_prefix} when source_prefix <= 112 ->
          <<a::8, b::8, c::8, d::8, e::8, f::8, g::8, h::8, i::8, j::8, k::8, l::8, m::8, n::8>> =
            addr

          {{Bitwise.<<<(a, 8) |> Bitwise.bor(b), Bitwise.<<<(c, 8) |> Bitwise.bor(d),
            Bitwise.<<<(e, 8) |> Bitwise.bor(f), Bitwise.<<<(g, 8) |> Bitwise.bor(h),
            Bitwise.<<<(i, 8) |> Bitwise.bor(j), Bitwise.<<<(k, 8) |> Bitwise.bor(l),
            Bitwise.<<<(m, 8) |> Bitwise.bor(n), 0}, source_prefix, scope_prefix}

        {2, source_prefix} when source_prefix <= 120 ->
          <<a::8, b::8, c::8, d::8, e::8, f::8, g::8, h::8, i::8, j::8, k::8, l::8, m::8, n::8,
            o::8>> = addr

          {{Bitwise.<<<(a, 8) |> Bitwise.bor(b), Bitwise.<<<(c, 8) |> Bitwise.bor(d),
            Bitwise.<<<(e, 8) |> Bitwise.bor(f), Bitwise.<<<(g, 8) |> Bitwise.bor(h),
            Bitwise.<<<(i, 8) |> Bitwise.bor(j), Bitwise.<<<(k, 8) |> Bitwise.bor(l),
            Bitwise.<<<(m, 8) |> Bitwise.bor(n), Bitwise.<<<(o, 8) |> Bitwise.bor(0)},
           source_prefix, scope_prefix}

        {2, source_prefix} when source_prefix <= 128 ->
          <<a::8, b::8, c::8, d::8, e::8, f::8, g::8, h::8, i::8, j::8, k::8, l::8, m::8, n::8,
            o::8, p::8>> = addr

          {{Bitwise.<<<(a, 8) |> Bitwise.bor(b), Bitwise.<<<(c, 8) |> Bitwise.bor(d),
            Bitwise.<<<(e, 8) |> Bitwise.bor(f), Bitwise.<<<(g, 8) |> Bitwise.bor(h),
            Bitwise.<<<(i, 8) |> Bitwise.bor(j), Bitwise.<<<(k, 8) |> Bitwise.bor(l),
            Bitwise.<<<(m, 8) |> Bitwise.bor(n), Bitwise.<<<(o, 8) |> Bitwise.bor(p)},
           source_prefix, scope_prefix}
      end
    end

    def parse(10, buffer) do
      case byte_size(buffer) do
        8 ->
          <<client::binary-size(8)>> = buffer
          {client, nil}

        size when size >= 16 and size <= 40 ->
          <<client::binary-size(8), server::binary>> = buffer
          {client, server}

        _ ->
          throw({:edns0_cookie, :size_error})
      end
    end

    def parse(_, buffer) do
      buffer
    end

    def encode(code, data)

    def encode(8, {addr, source_prefix, scope_prefix}) do
      case {tuple_size(addr), source_prefix} do
        {4, source_prefix} when source_prefix <= 8 ->
          <<1::16, source_prefix::8, scope_prefix::8, elem(addr, 0)::8>>

        {4, source_prefix} when source_prefix <= 16 ->
          <<1::16, source_prefix::8, scope_prefix::8, elem(addr, 0)::8, elem(addr, 1)::8>>

        {4, source_prefix} when source_prefix <= 24 ->
          <<1::16, source_prefix::8, scope_prefix::8, elem(addr, 0)::8, elem(addr, 1)::8,
            elem(addr, 2)::8>>

        {4, source_prefix} when source_prefix <= 32 ->
          <<1::16, source_prefix::8, scope_prefix::8, elem(addr, 0)::8, elem(addr, 1)::8,
            elem(addr, 2)::8, elem(addr, 3)::8>>

        {8, source_prefix} when source_prefix <= 8 ->
          a = elem(addr, 0)
          <<2::16, source_prefix::8, scope_prefix::8, Bitwise.>>>(a, 8)::8>>

        {8, source_prefix} when source_prefix <= 16 ->
          a = elem(addr, 0)
          <<2::16, source_prefix::8, scope_prefix::8, a::16>>

        {8, source_prefix} when source_prefix <= 24 ->
          a = elem(addr, 0)
          b = elem(addr, 1)
          <<2::16, source_prefix::8, scope_prefix::8, a::16, Bitwise.>>>(b, 8)::8>>

        {8, source_prefix} when source_prefix <= 32 ->
          a = elem(addr, 0)
          b = elem(addr, 1)
          <<2::16, source_prefix::8, scope_prefix::8, a::16, b::16>>

        {8, source_prefix} when source_prefix <= 40 ->
          a = elem(addr, 0)
          b = elem(addr, 1)
          c = elem(addr, 2)

          <<2::16, source_prefix::8, scope_prefix::8, a::16, b::16, Bitwise.>>>(c, 8)::8>>

        {8, source_prefix} when source_prefix <= 48 ->
          a = elem(addr, 0)
          b = elem(addr, 1)
          c = elem(addr, 2)

          <<2::16, source_prefix::8, scope_prefix::8, a::16, b::16, c::16>>

        {8, source_prefix} when source_prefix <= 56 ->
          a = elem(addr, 0)
          b = elem(addr, 1)
          c = elem(addr, 2)
          d = elem(addr, 3)

          <<2::16, source_prefix::8, scope_prefix::8, a::16, b::16, c::16, Bitwise.>>>(d, 8)::8>>

        {8, source_prefix} when source_prefix <= 64 ->
          a = elem(addr, 0)
          b = elem(addr, 1)
          c = elem(addr, 2)
          d = elem(addr, 3)

          <<2::16, source_prefix::8, scope_prefix::8, a::16, b::16, c::16, d::16>>

        {8, source_prefix} when source_prefix <= 72 ->
          a = elem(addr, 0)
          b = elem(addr, 1)
          c = elem(addr, 2)
          d = elem(addr, 3)
          e = elem(addr, 4)

          <<2::16, source_prefix::8, scope_prefix::8, a::16, b::16, c::16, d::16,
            Bitwise.>>>(e, 8)::8>>

        {8, source_prefix} when source_prefix <= 80 ->
          a = elem(addr, 0)
          b = elem(addr, 1)
          c = elem(addr, 2)
          d = elem(addr, 3)
          e = elem(addr, 4)

          <<2::16, source_prefix::8, scope_prefix::8, a::16, b::16, c::16, d::16, e::16>>

        {8, source_prefix} when source_prefix <= 88 ->
          a = elem(addr, 0)
          b = elem(addr, 1)
          c = elem(addr, 2)
          d = elem(addr, 3)
          e = elem(addr, 4)
          f = elem(addr, 5)

          <<2::16, source_prefix::8, scope_prefix::8, a::16, b::16, c::16, d::16, e::16,
            Bitwise.>>>(f, 8)::8>>

        {8, source_prefix} when source_prefix <= 96 ->
          a = elem(addr, 0)
          b = elem(addr, 1)
          c = elem(addr, 2)
          d = elem(addr, 3)
          e = elem(addr, 4)
          f = elem(addr, 5)

          <<2::16, source_prefix::8, scope_prefix::8, a::16, b::16, c::16, d::16, e::16, f::16>>

        {8, source_prefix} when source_prefix <= 104 ->
          a = elem(addr, 0)
          b = elem(addr, 1)
          c = elem(addr, 2)
          d = elem(addr, 3)
          e = elem(addr, 4)
          f = elem(addr, 5)
          g = elem(addr, 6)

          <<2::16, source_prefix::8, scope_prefix::8, a::16, b::16, c::16, d::16, e::16, f::16,
            Bitwise.>>>(g, 8)::8>>

        {8, source_prefix} when source_prefix <= 112 ->
          a = elem(addr, 0)
          b = elem(addr, 1)
          c = elem(addr, 2)
          d = elem(addr, 3)
          e = elem(addr, 4)
          f = elem(addr, 5)
          g = elem(addr, 6)

          <<2::16, source_prefix::8, scope_prefix::8, a::16, b::16, c::16, d::16, e::16, f::16,
            g::16>>

        {8, source_prefix} when source_prefix <= 120 ->
          a = elem(addr, 0)
          b = elem(addr, 1)
          c = elem(addr, 2)
          d = elem(addr, 3)
          e = elem(addr, 4)
          f = elem(addr, 5)
          g = elem(addr, 6)
          h = elem(addr, 7)

          <<2::16, source_prefix::8, scope_prefix::8, a::16, b::16, c::16, d::16, e::16, f::16,
            g::16, Bitwise.>>>(h, 8)::8>>

        {8, source_prefix} when source_prefix <= 128 ->
          a = elem(addr, 0)
          b = elem(addr, 1)
          c = elem(addr, 2)
          d = elem(addr, 3)
          e = elem(addr, 4)
          f = elem(addr, 5)
          g = elem(addr, 6)
          h = elem(addr, 7)

          <<2::16, source_prefix::8, scope_prefix::8, a::16, b::16, c::16, d::16, e::16, f::16,
            g::16, h::16>>
      end
    end

    def encode(10, {client, nil}) do
      <<client::binary-size(8)>>
    end

    def encode(10, {client, server}) do
      <<client::binary-size(8), server::binary>>
    end

    def encode(_, data) do
      data
    end

    def to_print({8, {ip, c, s}}) do
      "; ECS: #{YellowDog.Utils.a2s(ip)}/#{c}/#{s}"
    end

    def to_print({10, {c, s}}) do
      "; COOKIE: #{Base.encode16(c)}#{if(s != nil, do: " #{Base.encode16(s)}")}"
    end

    def to_print({code, data}) do
      "; #{code}: #{data}"
    end
  end
end
