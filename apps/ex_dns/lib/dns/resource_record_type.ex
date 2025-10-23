defmodule DNS.ResourceRecordType do
  @moduledoc """
  # DNS RRTypes
  DNS Resource Record Type

      Decimal 	Hex 	Registration Procedures 	Note
      0	0x0000	RRTYPE zero is used as a special indicator for the SIG RR [RFC2931], [RFC4034] and in other circumstances and must never be allocated for ordinary use.
      1-127	0x0000-0x007F	Expert Review (see mailing list information in [RFC6895]) or Standards Action	data TYPEs
      128-255	0x0080-0x00FF	Expert Review (see mailing list information in [RFC6895]) or Standards Action	Q TYPEs, Meta TYPEs
      256-61439	0x0100-0xEFFF	Expert Review (see mailing list information in [RFC6895]) or Standards Action	data RRTYPEs
      61440-65279	0xF000-0xFEFF	Reserved for future use (IETF Review required to define use)
      65280-65534	0xFF00-0xFFFE	Private Use
      65535	0xFFFF	Reserved (Standards Action)

      TYPE 	Value 	Meaning 	Reference 	Template 	Registration Date
      Reserved	0		[RFC6895]		2021-03-08
      A	1	a host address	[RFC1035]
      NS	2	an authoritative name server	[RFC1035]
      MD	3	a mail destination (OBSOLETE - use MX)	[RFC1035]
      MF	4	a mail forwarder (OBSOLETE - use MX)	[RFC1035]
      CNAME	5	the canonical name for an alias	[RFC1035]
      SOA	6	marks the start of a zone of authority	[RFC1035]
      7	a mailbox domain name (EXPERIMENTAL)	[RFC1035]
      MG	8	a mail group member (EXPERIMENTAL)	[RFC1035]
      MR	9	a mail rename domain name (EXPERIMENTAL)	[RFC1035]
      NULL	10	a null RR (EXPERIMENTAL)	[RFC1035]
      WKS	11	a well known service description	[RFC1035]
      PTR	12	a domain name pointer	[RFC1035]
      HINFO	13	host information	[RFC1035]
      MINFO	14	mailbox or mail list information	[RFC1035]
      MX	15	mail exchange	[RFC1035]
      TXT	16	text strings	[RFC1035]
      RP	17	for Responsible Person	[RFC1183]
      AFSDB	18	for AFS Data Base location	[RFC1183][RFC5864]
      X25	19	for X.25 PSDN address	[RFC1183]
      ISDN	20	for ISDN address	[RFC1183]
      RT	21	for Route Through	[RFC1183]
      NSAP	22	for NSAP address, NSAP style A record (DEPRECATED)	[RFC1706][status-change-int-tlds-to-historic]
      NSAP-PTR	23	for domain name pointer, NSAP style (DEPRECATED)	[RFC1706][status-change-int-tlds-to-historic]
      SIG	24	for security signature	[RFC2536][RFC2931][RFC3110][RFC4034]
      KEY	25	for security key	[RFC2536][RFC2539][RFC3110][RFC4034]
      PX	26	X.400 mail mapping information	[RFC2163]
      GPOS	27	Geographical Position	[RFC1712]
      AAAA	28	IP6 Address	[RFC3596]
      LOC	29	Location Information	[RFC1876]
      NXT	30	Next Domain (OBSOLETE)	[RFC2535][RFC3755]
      EID	31	Endpoint Identifier	[Michael_Patton][http://ana-3.lcs.mit.edu/~jnc/nimrod/dns.txt]		1995-06
      NIMLOC	32	Nimrod Locator	[1][Michael_Patton][http://ana-3.lcs.mit.edu/~jnc/nimrod/dns.txt]		1995-06
      SRV	33	Server Selection	[1][RFC2782]
      ATMA	34	ATM Address	[ ATM Forum Technical Committee, "ATM Name System, V2.0", Doc ID: AF-DANS-0152.000, July 2000. Available from and held in escrow by IANA.]
      NAPTR	35	Naming Authority Pointer	[RFC3403]
      KX	36	Key Exchanger	[RFC2230]
      CERT	37	CERT	[RFC4398]
      A6	38	A6 (OBSOLETE - use AAAA)	[RFC2874][RFC3226][RFC6563]
      DNAME	39	DNAME	[RFC6672]
      SINK	40	SINK	[Donald_E_Eastlake][draft-eastlake-kitchen-sink]		1997-11
      OPT	41	OPT	[RFC3225][RFC6891]
      APL	42	APL	[RFC3123]
      DS	43	Delegation Signer	[RFC4034]
      SSHFP	44	SSH Key Fingerprint	[RFC4255]
      IPSECKEY	45	IPSECKEY	[RFC4025]
      RRSIG	46	RRSIG	[RFC4034]
      NSEC	47	NSEC	[RFC4034][RFC9077]
      DNSKEY	48	DNSKEY	[RFC4034]
      DHCID	49	DHCID	[RFC4701]
      NSEC3	50	NSEC3	[RFC5155][RFC9077]
      NSEC3PARAM	51	NSEC3PARAM	[RFC5155]
      TLSA	52	TLSA	[RFC6698]
      SMIMEA	53	S/MIME cert association	[RFC8162]	SMIMEA/smimea-completed-template	2015-12-01
      Unassigned	54
      HIP	55	Host Identity Protocol	[RFC8005]
      NINFO	56	NINFO	[Jim_Reid]	NINFO/ninfo-completed-template	2008-01-21
      RKEY	57	RKEY	[Jim_Reid]	RKEY/rkey-completed-template	2008-01-21
      TALINK	58	Trust Anchor LINK	[Wouter_Wijngaards]	TALINK/talink-completed-template	2010-02-17
      CDS	59	Child DS	[RFC7344]	CDS/cds-completed-template	2011-06-06
      CDNSKEY	60	DNSKEY(s) the Child wants reflected in DS	[RFC7344]		2014-06-16
      OPENPGPKEY	61	OpenPGP Key	[RFC7929]	OPENPGPKEY/openpgpkey-completed-template	2014-08-12
      CSYNC	62	Child-To-Parent Synchronization	[RFC7477]		2015-01-27
      ZONEMD	63	Message Digest Over Zone Data	[RFC8976]	ZONEMD/zonemd-completed-template	2018-12-12
      SVCB	64	General-purpose service binding	[RFC9460]	SVCB/svcb-completed-template	2020-06-30
      HTTPS	65	SVCB-compatible type for use with HTTP	[RFC9460]	HTTPS/https-completed-template	2020-06-30
      Unassigned	66-98
      SPF	99		[RFC7208]
      UINFO	100		[IANA-Reserved]
      UID	101		[IANA-Reserved]
      GID	102		[IANA-Reserved]
      UNSPEC	103		[IANA-Reserved]
      NID	104		[RFC6742]	ILNP/nid-completed-template
      L32	105		[RFC6742]	ILNP/l32-completed-template
      L64	106		[RFC6742]	ILNP/l64-completed-template
      LP	107		[RFC6742]	ILNP/lp-completed-template
      EUI48	108	an EUI-48 address	[RFC7043]	EUI48/eui48-completed-template	2013-03-27
      EUI64	109	an EUI-64 address	[RFC7043]	EUI64/eui64-completed-template	2013-03-27
      Unassigned	110-248
      TKEY	249	Transaction Key	[RFC2930]
      TSIG	250	Transaction Signature	[RFC8945]
      IXFR	251	incremental transfer	[RFC1995]
      AXFR	252	transfer of an entire zone	[RFC1035][RFC5936]
      MAILB	253	mailbox-related RRs (MB, MG or MR)	[RFC1035]
      MAILA	254	mail agent RRs (OBSOLETE - see MX)	[RFC1035]
      *	255	A request for some or all records the server has available	[RFC1035][RFC6895][RFC8482]
      URI	256	URI	[RFC7553]	URI/uri-completed-template	2011-02-22
      CAA	257	Certification Authority Restriction	[RFC8659]	CAA/caa-completed-template	2011-04-07
      AVC	258	Application Visibility and Control	[Wolfgang_Riedel]	AVC/avc-completed-template	2016-02-26
      DOA	259	Digital Object Architecture	[draft-durand-doa-over-dns]	DOA/doa-completed-template	2017-08-30
      AMTRELAY	260	Automatic Multicast Tunneling Relay	[RFC8777]	AMTRELAY/amtrelay-completed-template	2019-02-06
      RESINFO	261	Resolver Information as Key/Value Pairs	[draft-ietf-add-resolver-info-06]	RESINFO/resinfo-completed-template	2023-11-02
      Unassigned	262-32767
      TA	32768	DNSSEC Trust Authorities	[Sam_Weiler][http://cameo.library.cmu.edu/][ Deploying DNSSEC Without a Signed Root. Technical Report 1999-19, Information Networking Institute, Carnegie Mellon University, April 2004.]		2005-12-13
      DLV	32769	DNSSEC Lookaside Validation (OBSOLETE)	[RFC8749][RFC4431]
      Unassigned	32770-65279
      Private use	65280-65534
      Reserved	65535

  # Reference
  - [iana](https://www.iana.org/assignments/dns-parameters/dns-parameters.xhtml#dns-parameters-4)
  - [DOMAIN NAMES - IMPLEMENTATION AND SPECIFICATION](https://tools.ietf.org/html/rfc1035)
  - [Domain Name System (DNS) IANA Considerations](https://tools.ietf.org/html/rfc6895)
  - [YANG Types for DNS Classes and Resource Record Types](https://tools.ietf.org/html/rfc9108)
  """

  alias DNS.ResourceRecordType

  @type t :: %__MODULE__{
          value: <<_::16>>
        }

  defstruct value: <<1::16>>

  @doc """
  # Create a new Class struct
  """
  @spec new(<<_::16>> | integer() | atom()) :: ResourceRecordType.t()
  def new(value) when is_integer(value), do: new(<<value::16>>)

  def new(value) when is_atom(value) do
    case value do
      :a -> new(1)
      :ns -> new(2)
      :cname -> new(5)
      :soa -> new(6)
      :ptr -> new(12)
      :mx -> new(15)
      :txt -> new(16)
      :aaaa -> new(28)
      :srv -> new(33)
      :nsec -> new(47)
      :dnskey -> new(48)
      :dhcid -> new(49)
      :nsec3 -> new(50)
      :nsec3param -> new(51)
      :tlsa -> new(52)
      :smimea -> new(53)
      :hip -> new(55)
      :cds -> new(59)
      :cdnskey -> new(60)
      :openpgpkey -> new(61)
      :csync -> new(62)
      :zonemd -> new(63)
      :svcb -> new(64)
      :https -> new(65)
      :ds -> new(43)
      :sshfp -> new(44)
      :ipseckey -> new(45)
      :rrsig -> new(46)
      _ -> throw("Unsupported atom RRType: #{value}")
    end
  end

  def new(value) do
    %ResourceRecordType{value: value}
  end

  defimpl DNS.Parameter, for: DNS.ResourceRecordType do
    @impl true
    def to_iodata(%DNS.ResourceRecordType{value: <<value::16>>}) do
      <<value::16>>
    end
  end

  defimpl String.Chars, for: DNS.ResourceRecordType do
    @impl true
    def to_string(%ResourceRecordType{value: value} = _rtype) do
      <<value::16>> = value

      case value do
        1 ->
          "A"

        2 ->
          "NS"

        3 ->
          "MD"

        4 ->
          "MF"

        5 ->
          "CNAME"

        6 ->
          "SOA"

        7 ->
          "MB"

        8 ->
          "MG"

        9 ->
          "MR"

        10 ->
          "NULL"

        11 ->
          "WKS"

        12 ->
          "PTR"

        13 ->
          "HINFO"

        14 ->
          "MINFO"

        15 ->
          "MX"

        16 ->
          "TXT"

        17 ->
          "RP"

        18 ->
          "AFSDB"

        19 ->
          "X25"

        20 ->
          "ISDN"

        21 ->
          "RT"

        22 ->
          "NSAP"

        23 ->
          "NSAP_PTR"

        24 ->
          "SIG"

        25 ->
          "KEY"

        26 ->
          "PX"

        27 ->
          "GPOS"

        28 ->
          "AAAA"

        29 ->
          "LOC"

        30 ->
          "NXT"

        31 ->
          "EID"

        32 ->
          "NIMLOC"

        33 ->
          "SRV"

        34 ->
          "ATMA"

        35 ->
          "NAPTR"

        36 ->
          "KX"

        37 ->
          "CERT"

        38 ->
          "A6"

        39 ->
          "DNAME"

        40 ->
          "SINK"

        41 ->
          "OPT"

        42 ->
          "APL"

        43 ->
          "DS"

        44 ->
          "SSHFP"

        45 ->
          "IPSECKEY"

        46 ->
          "RRSIG"

        47 ->
          "NSEC"

        48 ->
          "DNSKEY"

        49 ->
          "DHCID"

        50 ->
          "NSEC3"

        51 ->
          "NSEC3PARAM"

        52 ->
          "TLSA"

        53 ->
          "SMIMEA"

        54 ->
          "Unassigned(54)"

        55 ->
          "HIP"

        56 ->
          "NINFO"

        57 ->
          "RKEY"

        58 ->
          "TALINK"

        59 ->
          "CDS"

        60 ->
          "CDNSKEY"

        61 ->
          "OPENPGPKEY"

        62 ->
          "CSYNC"

        63 ->
          "ZONEMD"

        64 ->
          "SVCB"

        65 ->
          "HTTPS"

        99 ->
          "SPF"

        100 ->
          "UINFO"

        101 ->
          "UID"

        102 ->
          "GID"

        103 ->
          "UNSPEC"

        104 ->
          "NID"

        105 ->
          "L32"

        106 ->
          "L64"

        107 ->
          "LP"

        108 ->
          "EUI48"

        109 ->
          "EUI64"

        249 ->
          "TKEY"

        250 ->
          "TSIG"

        251 ->
          "IXFR"

        252 ->
          "AXFR"

        253 ->
          "MAILB"

        254 ->
          "MAILA"

        255 ->
          "ANY"

        256 ->
          "URI"

        257 ->
          "CAA"

        258 ->
          "AVC"

        259 ->
          "DOA"

        260 ->
          "AMTRELAY"

        261 ->
          "RESINFO"

        32768 ->
          "TA"

        32769 ->
          "DLV"

        value when value in [0, 65535] ->
          "Reserved(#{value})"

        value
        when value in 66..98 or value in 110..248 or value in 262..32767 or value in 32770..65279 ->
          "Unassigned(#{value})"

        value when value in 65280..65534 ->
          "Private use(#{value})"
      end
    end
  end

  defimpl Inspect, for: DNS.ResourceRecordType do
    import Inspect.Algebra

    @impl true
    def inspect(rr_type, _opts) do
      value = String.Chars.to_string(rr_type)
      concat(["#DNS.ResourceRecordType<", value, ">"])
    end
  end
end
