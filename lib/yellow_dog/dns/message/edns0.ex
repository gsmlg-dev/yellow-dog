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
  alias YellowDog.DNS.ResourceRecord.Type, as: RType

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
        <<0::8, 41::16, udp_payload::16, extended_rcode::8, version::8, do_bit::1, flags::7,
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
      edns0.do_bit::1, edns0.flags::7, encode_options(edns0.options)::binary>>
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
    options = [{code, opt_data} | options]

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
        parsed_value = value
        <<code::16, byte_size(parsed_value)::16, parsed_value::binary>>
      end
      |> Enum.join(<<>>)

    <<byte_size(opt_binary)::16, opt_binary::binary>>
  end
end
