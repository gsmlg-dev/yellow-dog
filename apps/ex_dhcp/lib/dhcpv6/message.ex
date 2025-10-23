defmodule DHCPv6.Message do
  @moduledoc """
  # DHCPv6 Message

  DHCPv6 message format and parsing according to [RFC3315](https://datatracker.ietf.org/doc/html/rfc3315).

  ## DHCPv6 Message Format

  DHCPv6 messages have a fixed-format header followed by options. The message
  format is much simpler than DHCPv4 as it omits many legacy BOOTP fields.

      0                   1                   2                   3
      0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
      +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
      |    msg-type   |               transaction-id (3 octets)       |
      +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+                               +
      |                                                               |
      .                            options                            .
      .                      (variable length)                      .
      |                                                               |
      +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+

  ## DHCPv6 Message Types

  DHCPv6 defines the following message types:

  - **1** - SOLICIT: Client broadcast to locate available servers
  - **2** - ADVERTISE: Server offers configuration parameters
  - **3** - REQUEST: Client requests configuration parameters
  - **4** - CONFIRM: Client verifies configuration parameters
  - **5** - RENEW: Client requests renewal of configuration parameters
  - **6** - REBIND: Client requests renewal without server contact
  - **7** - REPLY: Server responds to client request
  - **8** - RELEASE: Client releases assigned addresses
  - **9** - DECLINE: Client indicates address already in use
  - **10** - RECONFIGURE: Server initiates configuration renegotiation
  - **11** - INFORMATION-REQUEST: Client requests configuration only
  - **12** - RELAY-FORW: Relay agent forwards client message
  - **13** - RELAY-REPL: Relay agent forwards server reply

  ## DHCPv6 vs DHCPv4 Key Differences

  - **No legacy BOOTP fields**: DHCPv6 eliminates legacy BOOTP fields like
    htype, hlen, chaddr, etc.
  - **Larger address space**: Uses IPv6 addresses (128-bit vs 32-bit)
  - **Simplified header**: Fixed 4-byte header vs 236-byte DHCPv4 header
  - **Different option format**: 2-byte code + 2-byte length vs 1-byte code + 1-byte length
  - **DUID-based identification**: Uses DHCP Unique Identifiers instead of MAC addresses
  - **Multicast support**: Uses IPv6 multicast addresses instead of broadcasts

  ## DHCPv6 Option Overview

  DHCPv6 options are encoded using a two-octet option code followed by a
  two-octet option length, followed by the option data. Common options include:

  - **Option 1**: Client Identifier (DUID)
  - **Option 2**: Server Identifier (DUID)
  - **Option 3**: Identity Association for Non-temporary Addresses (IA_NA)
  - **Option 5**: Identity Association Address (IAADDR)
  - **Option 6**: Option Request List
  - **Option 23**: DNS Recursive Name Server
  """

  @type t :: %__MODULE__{
          msg_type: integer(),
          transaction_id: binary(),
          options: [DHCPv6.Message.Option.t()]
        }

  defstruct [
    :msg_type,
    :transaction_id,
    options: []
  ]

  @doc """
  Create a new DHCPv6 message.
  """
  @spec new() :: t()
  def new do
    %__MODULE__{
      msg_type: 0,
      transaction_id: <<0, 0, 0>>,
      options: []
    }
  end

  @doc """
  Parse DHCPv6 message from binary.
  """
  @spec from_iodata(binary()) :: {:ok, t()} | {:error, String.t()}
  def from_iodata(data) when is_binary(data) do
    case parse_message(data) do
      {:ok, message} -> {:ok, message}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Convert DHCPv6 message to binary.
  """
  @spec to_iodata(t()) :: binary()
  def to_iodata(message) do
    transaction_id =
      if byte_size(message.transaction_id) == 3, do: message.transaction_id, else: <<0, 0, 0>>

    header = <<message.msg_type, transaction_id::binary>>
    options_iolist = Enum.map(message.options, &DHCPv6.Message.Option.to_iodata/1)

    [header, options_iolist]
    |> IO.iodata_to_binary()
  end

  defp parse_message(<<msg_type, transaction_id::binary-size(3), rest::binary>>) do
    case parse_options(rest, []) do
      {:ok, options} ->
        {:ok,
         %__MODULE__{
           msg_type: msg_type,
           transaction_id: transaction_id,
           options: options
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_message(_), do: {:error, "Invalid DHCPv6 message format"}

  defp parse_options(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp parse_options(data, acc) do
    case DHCPv6.Message.Option.parse_option(data) do
      {:ok, option, rest} -> parse_options(rest, [option | acc])
      {:error, reason} -> {:error, reason}
    end
  end

  defimpl DHCP.Parameter, for: DHCPv6.Message do
    @impl true
    def to_iodata(message), do: DHCPv6.Message.to_iodata(message)
  end
end
