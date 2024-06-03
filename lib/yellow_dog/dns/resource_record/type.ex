defmodule YellowDog.DNS.ResourceRecord.Type do
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
      MB	7	a mailbox domain name (EXPERIMENTAL)	[RFC1035]
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

  @doc """
  # a host address
  """
  def a(), do: 1

  @doc """
  # an authoritative name server
  """
  def ns(), do: 2

  @doc """
  # a mail destination (OBSOLETE - use MX)
  """
  def md(), do: 3

  @doc """
  # a mail forwarder (OBSOLETE - use MX)
  """
  def mf(), do: 4

  @doc """
  # the canonical name for an alias
  """
  def cname(), do: 5

  @doc """
  # marks the start of a zone of authority
  """
  def soa(), do: 6

  @doc """
  # a mailbox domain name (EXPERIMENTAL)
  """
  def mb(), do: 7

  @doc """
  # a mail group member (EXPERIMENTAL)
  """
  def mg(), do: 8

  @doc """
  # a mail rename domain name (EXPERIMENTAL)
  """
  def mr(), do: 9

  @doc """
  # a null RR (EXPERIMENTAL)
  """
  def null(), do: 10

  @doc """
  # a well known service description
  """
  def wks(), do: 11

  @doc """
  # a domain name pointer
  """
  def ptr(), do: 12

  @doc """
  # host information
  """
  def hinfo(), do: 13

  @doc """
  # mailbox or mail list information
  """
  def minfo(), do: 14

  @doc """
  # mail exchange
  """
  def mx(), do: 15

  @doc """
  # text strings
  """
  def txt(), do: 16

  @doc """
  # for Responsible Person
  """
  def rp(), do: 17

  @doc """
  # for AFS Data Base location
  """
  def afsdb(), do: 18

  @doc """
  # for X.25 PSDN address
  """
  def x25(), do: 19

  @doc """
  # for ISDN address
  """
  def isdn(), do: 20

  @doc """
  # for Route Through
  """
  def rt(), do: 21

  @doc """
  # for NSAP address, NSAP style A record (DEPRECATED)
  """
  def nsap(), do: 22

  @doc """
  # for domain name pointer, NSAP style (DEPRECATED)
  """
  def nsap_ptr(), do: 23

  @doc """
  # for security signature
  """
  def sig(), do: 24

  @doc """
  # for security key
  """
  def key(), do: 25

  @doc """
  # X.400 mail mapping information
  """
  def px(), do: 26

  @doc """
  # Geographical Position
  """
  def gpos(), do: 27

  @doc """
  # IP6 Address
  """
  def aaaa(), do: 28

  @doc """
  # Location Information
  """
  def loc(), do: 29

  @doc """
  # Next Domain (OBSOLETE)
  """
  def nxt(), do: 30

  @doc """
  # Endpoint Identifier
  """
  def eid(), do: 31

  @doc """
  # Nimrod Locator
  """
  def nimloc(), do: 32

  @doc """
  # Server Selection
  """
  def srv(), do: 33

  @doc """
  # ATM Address (ATM Forum Technical Committee, "ATM Name System, V2.0", Doc ID: AF-DANS-0152.000, July 2000. Available from and held in escrow by IANA.)
  """
  def atma(), do: 34

  @doc """
  # Naming Authority Pointer
  """
  def naptr(), do: 35

  @doc """
  # Key Exchanger
  """
  def kx(), do: 36

  @doc """
  # CERT
  """
  def cert(), do: 37

  @doc """
  # A6 (OBSOLETE - use AAAA)
  """
  def a6(), do: 38

  @doc """
  # DNAME
  """
  def dname(), do: 39

  @doc """
  # SINK (Donald_E_Eastlake)(draft-eastlake-kitchen-sink)
  """
  def sink(), do: 40

  @doc """
  # OPT
  """
  def opt(), do: 41

  @doc """
  # APL
  """
  def apl(), do: 42

  @doc """
  # Delegation Signer
  """
  def ds(), do: 43

  @doc """
  # SSH Key Fingerprint
  """
  def sshfp(), do: 44

  @doc """
  # IPSECKEY
  """
  def ipseckey(), do: 45

  @doc """
  # RRSIG
  """
  def rrsig(), do: 46

  @doc """
  # NSEC
  """
  def nsec(), do: 47

  @doc """
  # DNSKEY
  """
  def dnskey(), do: 48

  @doc """
  # DHCID
  """
  def dhcid(), do: 49

  @doc """
  # NSEC3
  """
  def nsec3(), do: 50

  @doc """
  # NSEC3PARAM
  """
  def nsec3param(), do: 51

  @doc """
  # TLSA
  """
  def tlsa(), do: 52

  @doc """
  # S/MIME cert association
  """
  def smimea(), do: 53

  @doc """
  # Host Identity Protocol
  """
  def hip(), do: 55

  @doc """
  # NINFO
  """
  def ninfo(), do: 56

  @doc """
  # RKEY
  """
  def rkey(), do: 57

  @doc """
  # Trust Anchor LINK
  """
  def talink(), do: 58

  @doc """
  # Child DS
  """
  def cds(), do: 59

  @doc """
  # DNSKEY(s) the Child wants reflected in DS
  """
  def cdnskey(), do: 60

  @doc """
  # OpenPGP Key
  """
  def openpgpkey(), do: 61

  @doc """
  # Child-To-Parent Synchronization
  """
  def csync(), do: 62

  @doc """
  # Message Digest Over Zone Data
  """
  def zonemd(), do: 63

  @doc """
  # General-purpose service binding
  """
  def svcb(), do: 64

  @doc """
  # SVCB-compatible type for use with HTTP
  """
  def https(), do: 65

  @doc """
  # SPF
  """
  def spf(), do: 99

  @doc """
  # Transaction Key
  """
  def tkey(), do: 249

  @doc """
  # Transaction Signature
  """
  def tsig(), do: 250

  @doc """
  # incremental transfer
  """
  def ixfr(), do: 251

  @doc """
  # transfer of an entire zone
  """
  def axfr(), do: 252

  @doc """
  # mailbox-related RRs (MB, MG or MR)
  """
  def mailb(), do: 253

  @doc """
  # mail agent RRs (OBSOLETE - see MX)
  """
  def maila(), do: 254

  @doc """
  # A request for some or all records the server has available
  """
  def any(), do: 255

  @doc """
  # URI
  """
  def uri(), do: 256

  @doc """
  # Certification Authority Restriction
  """
  def caa(), do: 257

  @doc """
  # Application Visibility and Control
  """
  def avc(), do: 258

  @doc """
  # Digital Object Architecture
  """
  def doa(), do: 259

  @doc """
  # Automatic Multicast Tunneling Relay
  """
  def amtrelay(), do: 260

  @doc """
  # Resolver Information as Key/Value Pairs
  """
  def resinfo(), do: 261

  @doc """
  # DNSSEC Trust Authorities
  """
  def ta(), do: 32768

  @doc """
  # DNSSEC Lookaside Validation (OBSOLETE)
  """
  def dlv(), do: 32769

  def get_name(1), do: :a
  def get_name(2), do: :ns
  def get_name(3), do: :md
  def get_name(4), do: :mf
  def get_name(5), do: :cname
  def get_name(6), do: :soa
  def get_name(7), do: :mb
  def get_name(8), do: :mg
  def get_name(9), do: :mr
  def get_name(10), do: :null
  def get_name(11), do: :wks
  def get_name(12), do: :ptr
  def get_name(13), do: :hinfo
  def get_name(14), do: :minfo
  def get_name(15), do: :mx
  def get_name(16), do: :txt
  def get_name(17), do: :rp
  def get_name(18), do: :afsdb
  def get_name(19), do: :x25
  def get_name(20), do: :isdn
  def get_name(21), do: :rt
  def get_name(22), do: :nsap
  def get_name(23), do: :nsap_ptr
  def get_name(24), do: :sig
  def get_name(25), do: :key
  def get_name(26), do: :px
  def get_name(27), do: :gpos
  def get_name(28), do: :aaaa
  def get_name(29), do: :loc
  def get_name(30), do: :nxt
  def get_name(31), do: :eid
  def get_name(32), do: :nimloc
  def get_name(33), do: :srv
  def get_name(34), do: :atma
  def get_name(35), do: :naptr
  def get_name(36), do: :kx
  def get_name(37), do: :cert
  def get_name(38), do: :a6
  def get_name(39), do: :dname
  def get_name(40), do: :sink
  def get_name(41), do: :opt
  def get_name(42), do: :apl
  def get_name(43), do: :ds
  def get_name(44), do: :sshfp
  def get_name(45), do: :ipseckey
  def get_name(46), do: :rrsig
  def get_name(47), do: :nsec
  def get_name(48), do: :dnskey
  def get_name(49), do: :dhcid
  def get_name(50), do: :nsec3
  def get_name(51), do: :nsec3param
  def get_name(52), do: :tlsa
  def get_name(53), do: :smimea
  def get_name(55), do: :hip
  def get_name(56), do: :ninfo
  def get_name(57), do: :rkey
  def get_name(58), do: :talink
  def get_name(59), do: :cds
  def get_name(60), do: :cdnskey
  def get_name(61), do: :openpgpkey
  def get_name(62), do: :csync
  def get_name(63), do: :zonemd
  def get_name(64), do: :svcb
  def get_name(65), do: :https
  def get_name(99), do: :spf
  def get_name(249), do: :tkey
  def get_name(250), do: :tsig
  def get_name(251), do: :ixfr
  def get_name(252), do: :axfr
  def get_name(253), do: :mailb
  def get_name(254), do: :maila
  def get_name(255), do: :any
  def get_name(256), do: :uri
  def get_name(257), do: :caa
  def get_name(258), do: :avc
  def get_name(259), do: :doa
  def get_name(260), do: :amtrelay
  def get_name(261), do: :resinfo
  def get_name(32768), do: :ta
  def get_name(32769), do: :dlv
  def get_name(code), do: code
end
