defmodule DNS.Class do
  @moduledoc """
  # DNS Class

  # Note
  As noted in [RFC6762], Multicast DNS can only carry DNS records with classes in the range 0-32767.
  Classes in the range 32768 to 65535 are incompatible with Multicast DNS. But Multicast DNS uses the
  32768(0x8000) as a special value to indicate a cache-flush request.

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

  # Multicasd DNS [RFC6762](https://datatracker.ietf.org/doc/html/rfc6762)

   The value 0x8001 in the rrclass field
   of a resource record in a Multicast DNS response message indicates a
   resource record with class 1, with the cache-flush bit set.  When
   receiving a resource record with the cache-flush bit set,
   implementations should take care to mask off that bit before storing
   the resource record in memory, or otherwise ensure that it is given
   the correct semantic interpretation.

  # Reference
  - [iana](https://www.iana.org/assignments/dns-parameters/dns-parameters.xhtml#dns-parameters-2)
  - [Domain Name System (DNS) IANA Considerations](https://tools.ietf.org/html/rfc6895)
  - [YANG Types for DNS Classes and Resource Record Types](https://tools.ietf.org/html/rfc9108)
  """

  @type t :: %__MODULE__{value: <<_::16>>}

  alias DNS.Class

  defstruct value: <<0::16>>

  @doc """
  # Create a new Class struct
  """
  @spec new(<<_::16>> | integer() | atom()) :: Class.t()
  def new(value) when is_integer(value) do
    %Class{value: <<value::16>>}
  end

  def new(value) when is_atom(value) do
    case value do
      :in -> new(1)
      :ch -> new(3)
      :hs -> new(4)
      :none -> new(254)
      :any -> new(255)
      _ -> throw("Unsupported atom class: #{value}")
    end
  end

  def new(value) do
    %Class{value: value}
  end

  def internet() do
    new(1)
  end
end

defimpl DNS.Parameter, for: DNS.Class do
  @impl true
  def to_iodata(%DNS.Class{value: <<value::16>>}) do
    <<value::16>>
  end
end

defimpl String.Chars, for: DNS.Class do
  @impl true
  @spec to_string(DNS.Class.t()) :: binary()
  def to_string(class) do
    <<value::16>> = class.value

    case value do
      1 -> "IN"
      3 -> "CH"
      4 -> "HS"
      254 -> "NONE"
      255 -> "ANY"
      0x8001 -> "IN+"
      value when value in [0, 65535] -> "Reserved(#{value})"
      value when value == 2 or value in 5..253 or value in 256..65279 -> "Unassigned(#{value})"
      value when value in 65280..65534 -> "Reserved_for_Private_Use(#{value})"
    end
  end
end

defimpl Inspect, for: DNS.Class do
  import Inspect.Algebra

  @impl true
  def inspect(dns_class, _opts) do
    value = String.Chars.to_string(dns_class)
    concat(["#DNS.Class<", value, ">"])
  end
end
