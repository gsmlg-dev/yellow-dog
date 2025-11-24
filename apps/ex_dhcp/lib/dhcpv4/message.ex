defmodule DHCPv4.Message do
  @moduledoc """
  DHCPv4 message structure and parsing implementation.

  This module provides comprehensive DHCPv4 message parsing and serialization
  based on [RFC 2131](https://datatracker.ietf.org/doc/html/rfc2131). It supports
  the complete DHCPv4 message format including all header fields and options.

  # DHCP Message Format

      Format of a DHCP message

      0                   1                   2                   3
      0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
      +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
      |     op (1)    |   htype (1)   |   hlen (1)    |   hops (1)    |
      +---------------+---------------+---------------+---------------+
      |                            xid (4)                            |
      +-------------------------------+-------------------------------+
      |           secs (2)            |           flags (2)           |
      +-------------------------------+-------------------------------+
      |                          ciaddr  (4)                          |
      +---------------------------------------------------------------+
      |                          yiaddr  (4)                          |
      +---------------------------------------------------------------+
      |                          siaddr  (4)                          |
      +---------------------------------------------------------------+
      |                          giaddr  (4)                          |
      +---------------------------------------------------------------+
      |                                                               |
      |                          chaddr  (16)                         |
      |                                                               |
      |                                                               |
      +---------------------------------------------------------------+
      |                                                               |
      |                          sname   (64)                         |
      +---------------------------------------------------------------+
      |                                                               |
      |                          file    (128)                        |
      +---------------------------------------------------------------+
      |                                                               |
      |                          options (variable)                   |
      +---------------------------------------------------------------+


   DHCP defines a new 'client identifier' option that is used to pass an
   explicit client identifier to a DHCP server.  This change eliminates
   the overloading of the 'chaddr' field in BOOTP messages, where
   'chaddr' is used both as a hardware address for transmission of BOOTP
   reply messages and as a client identifier.  The 'client identifier'
   is an opaque key, not to be interpreted by the server; for example,
   the 'client identifier' may contain a hardware address, identical to
   the contents of the 'chaddr' field, or it may contain another type of
   identifier, such as a DNS name.  The 'client identifier' chosen by a
   DHCP client MUST be unique to that client within the subnet to which
   the client is attached. If the client uses a 'client identifier' in
   one message, it MUST use that same identifier in all subsequent
   messages, to ensure that all servers correctly identify the client.

   DHCP clarifies the interpretation of the 'siaddr' field as the
   address of the server to use in the next step of the client's
   bootstrap process.  A DHCP server may return its own address in the
   'siaddr' field, if the server is prepared to supply the next
   bootstrap service (e.g., delivery of an operating system executable
   image).  A DHCP server always returns its own address in the 'server
   identifier' option.

      Description of fields in a DHCP message

      FIELD      OCTETS       DESCRIPTION
      -----      ------       -----------

      op            1  Message op code / message type.
                        1 = BOOTREQUEST, 2 = BOOTREPLY
      htype         1  Hardware address type, see ARP section in "Assigned
                        Numbers" RFC; e.g., '1' = 10mb ethernet.
      hlen          1  Hardware address length (e.g.  '6' for 10mb
                        ethernet).
      hops          1  Client sets to zero, optionally used by relay agents
                        when booting via a relay agent.
      xid           4  Transaction ID, a random number chosen by the
                        client, used by the client and server to associate
                        messages and responses between a client and a
                        server.
      secs          2  Filled in by client, seconds elapsed since client
                        began address acquisition or renewal process.
      flags         2  Flags (see figure 2).
      ciaddr        4  Client IP address; only filled in if client is in
                        BOUND, RENEW or REBINDING state and can respond
                        to ARP requests.
      yiaddr        4  'your' (client) IP address.
      siaddr        4  IP address of next server to use in bootstrap;
                        returned in DHCPOFFER, DHCPACK by server.
      giaddr        4  Relay agent IP address, used in booting via a
                        relay agent.
      chaddr       16  Client hardware address.
      sname        64  Optional server host name, null terminated string.
      file        128  Boot file name, null terminated string; "generic"
                        name or null in DHCPDISCOVER, fully qualified
                        directory-path name in DHCPOFFER.
      options     var  Optional parameters field.  See the options
                        documents for a list of defined options.

   The 'options' field is now variable length. A DHCP client must be
   prepared to receive DHCP messages with an 'options' field of at least
   length 312 octets.  This requirement implies that a DHCP client must
   be prepared to receive a message of up to 576 octets, the minimum IP
   datagram size an IP host must be prepared to accept [3].  DHCP
   clients may negotiate the use of larger DHCP messages through the
   'maximum DHCP message size' option.  The options field may be further
   extended into the 'file' and 'sname' fields.

   In the case of a client using DHCP for initial configuration (before
   the client's TCP/IP software has been completely configured), DHCP
   requires creative use of the client's TCP/IP software and liberal
   interpretation of RFC 1122.  The TCP/IP software SHOULD accept and
   forward to the IP layer any IP packets delivered to the client's
   hardware address before the IP address is configured; DHCP servers
   and BOOTP relay agents may not be able to deliver DHCP messages to
   clients that cannot accept hardware unicast datagrams before the
   TCP/IP software is configured.

   To work around some clients that cannot accept IP unicast datagrams
   before the TCP/IP software is configured as discussed in the previous
   paragraph, DHCP uses the 'flags' field [21].  The leftmost bit is
   defined as the BROADCAST (B) flag.  The semantics of this flag are
   discussed in section 4.1 of this document.  The remaining bits of the
   flags field are reserved for future use.  They MUST be set to zero by
   clients and ignored by servers and relay agents.  Figure 2 gives the
   format of the 'flags' field.

      Format of the 'flags' field

                          1 1 1 1 1 1
      0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5
      +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
      |B|             MBZ             |
      +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+

      B:  BROADCAST flag

      MBZ:  MUST BE ZERO (reserved for future use)

  """

  alias DHCPv4.Message.Option

  @type t :: %__MODULE__{
          op: 0..255,
          htype: 0..255,
          hlen: 0..255,
          hops: 0..255,
          xid: 0..4_294_967_295,
          secs: 0..65535,
          flags: 0..65535,
          ciaddr: :inet.ip4_address(),
          yiaddr: :inet.ip4_address(),
          siaddr: :inet.ip4_address(),
          giaddr: :inet.ip4_address(),
          chaddr: <<_::_*16>>,
          sname: <<_::_*64>>,
          file: <<_::_*128>>,
          options: [Option.t()]
        }

  defstruct op: nil,
            htype: nil,
            hlen: nil,
            hops: nil,
            xid: nil,
            secs: nil,
            flags: nil,
            ciaddr: nil,
            yiaddr: nil,
            siaddr: nil,
            giaddr: nil,
            chaddr: nil,
            sname: nil,
            file: nil,
            options: []

  @spec new() :: t()
  def new() do
    %__MODULE__{
      op: 0,
      htype: 0,
      hlen: 0,
      hops: 0,
      xid: 0,
      secs: 0,
      flags: 0,
      ciaddr: {0, 0, 0, 0},
      yiaddr: {0, 0, 0, 0},
      siaddr: {0, 0, 0, 0},
      giaddr: {0, 0, 0, 0},
      chaddr: <<0::8*16>>,
      sname: <<0::8*64>>,
      file: <<0::8*128>>,
      options: []
    }
  end

  @doc """
  Parse DHCPv4 message from binary data.

  ## Parameters

    * `data` - Binary data containing DHCPv4 message

  ## Returns

    * `t()` - Parsed DHCPv4 message struct

  ## Examples

      iex> message_data = <<1, 1, 6, 0, 0x12345678::32, 0, 0, 0::32, 0::32, 0::32, 0::32,
      ...>                    0::16*8, 0::8*64, 0::8*128, 99, 130, 83, 99, 255>>
      iex> message = DHCPv4.Message.from_iodata(message_data)
      iex> message.op
      1
      iex> message.xid
      0x12345678

  """
  @spec from_iodata(binary()) :: t()
  def from_iodata(
        <<op::8, htype::8, hlen::8, hops::8, xid::32, secs::16, flags::16, ciaddr::32, yiaddr::32,
          siaddr::32, giaddr::32, chaddr::binary-size(16), sname::binary-size(64),
          file::binary-size(128), options::binary>>
      ) do
    case Option.parse(options) do
      {:ok, parsed_options} ->
        %__MODULE__{
          op: op,
          htype: htype,
          hlen: hlen,
          hops: hops,
          xid: xid,
          secs: secs,
          flags: flags,
          ciaddr: binary_to_ip4_address(<<ciaddr::32>>),
          yiaddr: binary_to_ip4_address(<<yiaddr::32>>),
          siaddr: binary_to_ip4_address(<<siaddr::32>>),
          giaddr: binary_to_ip4_address(<<giaddr::32>>),
          chaddr: chaddr,
          sname: sname,
          file: file,
          options: parsed_options
        }

      {:error, reason} ->
        raise ArgumentError, "Failed to parse DHCP options: #{reason}"
    end
  end

  # Convert 32-bit binary to IPv4 address tuple
  defp binary_to_ip4_address(<<a::8, b::8, c::8, d::8>>) do
    {a, b, c, d}
  end

  defimpl DHCP.Parameter, for: DHCPv4.Message do
    @impl true
    def to_iodata(%DHCPv4.Message{} = message) do
      <<message.op::8, message.htype::8, message.hlen::8, message.hops::8, message.xid::32,
        message.secs::16, message.flags::16, message.ciaddr::32, message.yiaddr::32,
        message.siaddr::32, message.giaddr::32, message.chaddr::binary-size(16),
        message.sname::binary-size(64), message.file::binary-size(128),
        Option.to_dhcp_binary(message.options)::binary>>
    end
  end

  defimpl String.Chars, for: DHCPv4.Message do
    def to_string(%DHCPv4.Message{} = message) do
      """
      === DHCP Message ===
      Operation: #{message.op}
      Hardware Type: #{message.htype}
      Hardware Address Length: #{message.hlen}
      Hops: #{message.hops}
      Transaction ID: #{message.xid}
      Seconds: #{message.secs}
      Flags: #{message.flags}
      Client IP Address: #{message.ciaddr |> :inet.ntoa()}
      Your IP Address: #{message.yiaddr |> :inet.ntoa()}
      Server IP Address: #{message.siaddr |> :inet.ntoa()}
      Gateway IP Address: #{message.giaddr |> :inet.ntoa()}
      Client Hardware Address: #{parse_mac_address(message.chaddr, message.hlen)}
      Server Name: #{message.sname |> String.trim(<<0>>)}
      File: #{message.file |> String.trim(<<0>>)}

      === DHCP Options ===
      #{Enum.map(message.options, &Kernel.to_string/1) |> Enum.join("")}
      """
    end

    defp parse_mac_address(chaddr, hlen) do
      chaddr
      |> :binary.part(0, hlen)
      |> Base.encode16(case: :lower)
      |> String.replace(~r/(..)/, "\\1:")
      |> String.trim_trailing(":")
    end
  end
end
