defmodule DNS.Message.RCode do
  @moduledoc """
  # DNS RCode
  DNS return code

  It would appear from the DNS header that only four bits of
  RCODE, or response/error code, are available.  However, RCODEs can
  appear not only at the top level of a DNS response but also inside
  TSIG RRs [RFC2845], TKEY RRs [RFC2930], and extended by OPT RRs
  [RFC6891].  The OPT RR provides an 8-bit extension to the 4 header
  bits, resulting in a 12-bit RCODE field, and the TSIG and TKEY RRs
  have a 16-bit field designated in their RFCs as the "Error" field.

  Error codes appearing in the DNS header and in these other RR types
  all refer to the same error code space with the exception of error
  code 16, which has a different meaning in the OPT RR than in the TSIG
  RR, and error code 9, whose variations are described after the table
  below.  The duplicate assignment of 16 was accidental.  To the extent
  that any prior RFCs imply any sort of different error number space
  for the OPT, TSIG, or TKEY RRs, they are superseded by this unified
  DNS error number space.  (This paragraph is the reason this document
  updates [RFC2845] and [RFC2930].)  With the existing exceptions of
  error numbers 9 and 16, the same error number must not be assigned
  for different errors even if they would only occur in different RR
  types.  See table below.

      Range 	Registration Procedures
      0-3840	IETF Review
      3841-4095	Private Use
      4096-65534	IETF Review
      65535	Reserved (Standards Action)

      RCODE 	Name 	Description 	Reference
      0	NoError	No Error	[RFC1035]
      1	FormErr	Format Error	[RFC1035]
      2	ServFail	Server Failure	[RFC1035]
      3	NXDomain	Non-Existent Domain	[RFC1035]
      4	NotImp	Not Implemented	[RFC1035]
      5	Refused	Query Refused	[RFC1035]
      6	YXDomain	Name Exists when it should not	[RFC2136][RFC6672]
      7	YXRRSet	RR Set Exists when it should not	[RFC2136]
      8	NXRRSet	RR Set that should exist does not	[RFC2136]
      9	NotAuth	Server Not Authoritative for zone	[RFC2136]
      9	NotAuth	Not Authorized	[RFC8945]
      10	NotZone	Name not contained in zone	[RFC2136]
      11	DSOTYPENI	DSO-TYPE Not Implemented	[RFC8490]
      12-15	Unassigned
      16	BADVERS	Bad OPT Version	[RFC6891]
      16	BADSIG	TSIG Signature Failure	[RFC8945]
      17	BADKEY	Key not recognized	[RFC8945]
      18	BADTIME	Signature out of time window	[RFC8945]
      19	BADMODE	Bad TKEY Mode	[RFC2930]
      20	BADNAME	Duplicate key name	[RFC2930]
      21	BADALG	Algorithm not supported	[RFC2930]
      22	BADTRUNC	Bad Truncation	[RFC8945]
      23	BADCOOKIE	Bad/missing Server Cookie	[RFC7873]
      24-3840	Unassigned
      3841-4095	Reserved for Private Use		[RFC6895]
      4096-65534	Unassigned
      65535	Reserved, can be allocated by Standards Action		[RFC6895]

  # Reference
  - [iana](https://www.iana.org/assignments/dns-parameters/dns-parameters.xhtml#dns-parameters-6)
  - [DOMAIN NAMES - IMPLEMENTATION AND SPECIFICATION](https://tools.ietf.org/html/rfc1035)
  - [Domain Name System (DNS) IANA Considerations](https://tools.ietf.org/html/rfc6895)
  """
  alias DNS.Message.RCode

  defstruct value: nil, extended: <<0::8>>

  @type t :: %__MODULE__{value: <<_::4>>, extended: <<_::8>>}

  def new(value) when is_integer(value) and value in 0..15, do: new(<<value::4>>)

  def new(value) do
    %RCode{value: value}
  end

  @spec extend(DNS.Message.RCode.t(), any()) :: DNS.Message.RCode.t()
  def extend(rcode = %RCode{}, extended) when is_integer(extended),
    do: extend(rcode, <<extended::8>>)

  def extend(rcode = %RCode{}, extended), do: %{rcode | extended: extended}

  def no_error(), do: new(0)
  def form_err(), do: new(1)
  def serv_fail(), do: new(2)
  def nx_domain(), do: new(3)
  def not_imp(), do: new(4)
  def refused(), do: new(5)
  def yx_domain(), do: new(6)
  def yx_rrset(), do: new(7)
  def nx_rrset(), do: new(8)
  def not_auth(), do: new(9)
  def not_zone(), do: new(10)
  def dso_type_ni(), do: new(11)

  defimpl DNS.Parameter, for: DNS.Message.RCode do
    @impl true
    def to_iodata(%DNS.Message.RCode{value: value}) do
      value
    end
  end

  defimpl String.Chars, for: DNS.Message.RCode do
    @impl true
    @spec to_string(DNS.Message.RCode.t()) :: binary()
    def to_string(rcode) do
      <<value::4>> = rcode.value

      if rcode.extended == <<0::8>> do
        case value do
          0 -> "NoError"
          1 -> "FormErr"
          2 -> "ServFail"
          3 -> "NXDomain"
          4 -> "NotImp"
          5 -> "Refused"
          6 -> "YXDomain"
          7 -> "YXRRSet"
          8 -> "NXRRSet"
          9 -> "NotAuth"
          10 -> "NotZone"
          11 -> "DSOTYPENI"
          value when value in 12..15 -> "Unassigned(#{value})"
          value -> "Unassigned(#{value})"
        end
      else
        "Extended(#{value},#{rcode.extended})"
      end
    end
  end
end
