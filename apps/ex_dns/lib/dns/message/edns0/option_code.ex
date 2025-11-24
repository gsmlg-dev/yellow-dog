defmodule DNS.Message.EDNS0.OptionCode do
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

  @type t :: %__MODULE__{value: <<_::16>>}

  alias DNS.Message.EDNS0.OptionCode

  defstruct value: <<0::16>>

  @doc """
  # Create a new OptionCode struct
  """
  @spec new(<<_::16>> | integer()) :: OptionCode.t()
  def new(value) when is_integer(value) do
    %OptionCode{value: <<value::16>>}
  end

  def new(value) do
    %OptionCode{value: value}
  end

  defimpl DNS.Parameter, for: OptionCode do
    @impl true
    def to_iodata(%OptionCode{value: <<value::16>>}) do
      <<value::16>>
    end
  end

  defimpl String.Chars, for: OptionCode do
    @impl true
    @spec to_string(OptionCode.t()) :: binary()
    def to_string(option_code) do
      <<value::16>> = option_code.value

      case value do
        0 ->
          "Reserved(0)"

        1 ->
          "LLQ"

        2 ->
          "Update Lease"

        3 ->
          "NSID"

        4 ->
          "Reserved(4)"

        5 ->
          "DAU"

        6 ->
          "DHU"

        7 ->
          "N3U"

        8 ->
          "edns-client-subnet"

        9 ->
          "EDNS EXPIRE"

        10 ->
          "COOKIE"

        11 ->
          "edns-tcp-keepalive"

        12 ->
          "Padding"

        13 ->
          "CHAIN"

        14 ->
          "edns-key-tag"

        15 ->
          "Extended DNS Error"

        16 ->
          "EDNS-Client-Tag"

        17 ->
          "EDNS-Server-Tag"

        18 ->
          "Report-Channel"

        value when value in 19..20291 or value in 20293..26945 or value in 26947..65000 ->
          "Unassigned(#{value})"

        20292 ->
          "Umbrella Ident"

        26946 ->
          "DeviceID"

        value when value in 65001..65534 ->
          "Reserved for Local/Experimental Use(#{value})"

        65535 ->
          "Reserved for future expansion"
      end
    end
  end
end
