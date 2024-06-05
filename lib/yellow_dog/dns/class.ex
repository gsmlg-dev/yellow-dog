defmodule YellowDog.DNS.Class do
  @moduledoc """
  # DNS Class

  # Note
  As noted in [RFC6762], Multicast DNS can only carry DNS records with classes in the range 0-32767.
  Classes in the range 32768 to 65535 are incompatible with Multicast DNS.

  # Note
  When this registry is modified, the YANG module [iana-dns-class-rr-type]
  must be updated as defined in [RFC9108].

      Decimal 	Hex 	Registration Procedures 	Note
      0	0x0000	Standards Action
      1-127	0x0000-0x007F	IETF Review	data CLASSes only
      128-253	0x0080-0x00FD	IETF Review	QCLASSes and meta-CLASSes only
      256-32767	0x0100-0x7FFF	IETF Review
      32768-57343	0x8000-0xDFFF	Specification Required	data CLASSes only
      57344-65279	0xE000-0xFEFF	Specification Required	QCLASSes and meta-CLASSes only
      65280-65534	0xFF00-0xFFFE	Private Use
      65535	0xFFFF	Standards Action

      Decimal 	Hexadecimal 	Name 	Reference
      0	0x0000	Reserved	[RFC6895]
      1	0x0001	Internet (IN)	[RFC1035]
      2	0x0002	Unassigned
      3	0x0003	Chaos (CH)	[D. Moon, "Chaosnet", A.I. Memo 628, Massachusetts Institute of Technology Artificial Intelligence Laboratory, June 1981.]
      4	0x0004	Hesiod (HS)	[Dyer, S., and F. Hsu, "Hesiod", Project Athena Technical Plan - Name Service, April 1987.]
      5-253	0x0005-0x00FD	Unassigned
      254	0x00FE	QCLASS NONE	[RFC2136]
      255	0x00FF	QCLASS * (ANY)	[RFC1035]
      256-65279	0x0100-0xFEFF	Unassigned
      65280-65534	0xFF00-0xFFFE	Reserved for Private Use	[RFC6895]
      65535	0xFFFF	Reserved	[RFC6895]

  # Reference
  - [iana](https://www.iana.org/assignments/dns-parameters/dns-parameters.xhtml#dns-parameters-2)
  - [Domain Name System (DNS) IANA Considerations](https://tools.ietf.org/html/rfc6895)
  - [YANG Types for DNS Classes and Resource Record Types](https://tools.ietf.org/html/rfc9108)
  """

  defstruct value: <<0::16>>

  def validate!(value) when 0 <= value and value <= 65535 do
    %YellowDog.DNS.Class{value: value}
  end

  def validate!(_) do
    raise ArgumentError, "Value must be between 0 and 65535"
  end

  @doc """
  # Reserved
  """
  @spec reserved() :: 0
  def reserved(), do: 0

  @doc """
  # Internet (IN)
  """
  @spec internet() :: 1
  def internet(), do: 1

  @doc """
  # Chaos (CH)
  """
  @spec chaos() :: 3
  def chaos(), do: 3

  @doc """
  # Hesiod (HS)
  """
  @spec hesiod() :: 4
  def hesiod(), do: 4

  @doc """
  # QCLASS NONE
  """
  @spec qclass_none() :: 254
  def qclass_none(), do: 254

  @doc """
  # QCLASS * (ANY)
  """
  @spec qclass_any() :: 255
  def qclass_any(), do: 255

  def get_name(0), do: :reserved
  def get_name(1), do: :internet
  def get_name(3), do: :chaos
  def get_name(4), do: :hesiod
  def get_name(254), do: :qclass_none
  def get_name(255), do: :qclass_any
  def get_name(code), do: code

  def to_print(code)
  def to_print(1), do: "IN"
  def to_print(3), do: "CH"
  def to_print(4), do: "HS"
  def to_print(254), do: "NONE"
  def to_print(255), do: "ANY"
  def to_print(code) when code == 0 or code == 65535, do: "Reserved(#{code})"

  def to_print(code)
      when code == 2 or (code >= 5 and code <= 253) or (code >= 256 and code <= 65279),
      do: "Unassigned(#{code})"

  def to_print(code) when code >= 65280 and code <= 65280, do: "Reserved_for_Private_Use(#{code})"
end
