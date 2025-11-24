defmodule DHCPv6.Message.Option do
  @moduledoc """
  # DHCPv6 Option

  DHCPv6 Options and Configuration Parameters [RFC3315](https://datatracker.ietf.org/doc/html/rfc3315)
  and [RFC3646](https://datatracker.ietf.org/doc/html/rfc3646)

  DHCPv6 uses a different option format than DHCPv4. Options in DHCPv6 are
  encoded using a two-octet option code followed by a two-octet option length,
  followed by the option data.

  ## Option Format

      0                   1                   2                   3
      0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
      +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
      |          option-code          |           option-len          |
      +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
      |                          option-data                          |
      |                      (option-len octets)                      |
      +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+

  ## Common DHCPv6 Options

  **Client Identifier (Option 1)**

  The Client Identifier option is used to carry a DUID (DHCP Unique Identifier)
  associated with the client. Each DHCPv6 client and server has a DUID.

  The format is:

      Code   Len   DUID
    +-----+-----+-----+-----+---
    |  1  |  n  | d1  | d2  | ...
    +-----+-----+-----+-----+---

  **Server Identifier (Option 2)**

  The Server Identifier option is used to carry a DUID associated with the server.

  The format is:

      Code   Len   DUID
    +-----+-----+-----+-----+---
    |  2  |  n  | d1  | d2  | ...
    +-----+-----+-----+-----+---

  **Identity Association for Non-temporary Addresses (IA_NA) (Option 3)**

  The IA_NA option is used to carry an IA_NA, the parameters associated with it,
  and the addresses associated with it.

  The format is:

      Code   Len   IAID  T1    T2    IA_NA-options
    +-----+-----+-----+-----+-----+-----+-----+---
    |  3  |  n  | iaid| t1  | t2  | opt1| opt2| ...
    +-----+-----+-----+-----+-----+-----+-----+---

  **Identity Association for Temporary Addresses (IA_TA) (Option 4)**

  The IA_TA option is used to carry an IA_TA, the parameters associated with it,
  and the addresses associated with it.

  **Identity Association Address (IAADDR) (Option 5)**

  The IAADDR option is used to specify IPv6 addresses associated with an IA_NA or
  IA_TA.

  The format is:

      Code   Len   IPv6-address  preferred-lifetime  valid-lifetime  IAADDR-options
    +-----+-----+-----+-----+-----+-----+-----+-----+-----+-----+-----+---
    |  5  |  n  | a1  | a2  | a3  | a4  | a5  | a6  | a7  | a8  | opt1| ...
    +-----+-----+-----+-----+-----+-----+-----+-----+-----+-----+-----+---

  **Option Request (Option 6)**

  The Option Request option is used to identify a list of options in a message
  between a client and a server.

  The format is:

      Code   Len   option-code-1  option-code-2  ...
    +-----+-----+-----+-----+-----+-----+---
    |  6  |  n  | c1  | c2  | c3  | c4  | ...
    +-----+-----+-----+-----+-----+-----+---

  **Preference (Option 7)**

  The Preference option is sent by servers to control the selection of a server
  by the client.

  The format is:

      Code   Len   pref-value
    +-----+-----+-----+
    |  7  |  1  | pref|
    +-----+-----+-----+

  **Elapsed Time (Option 8)**

  The Elapsed Time option is used to indicate how long a client has been trying
  to complete a DHCPv6 message exchange.

  The format is:

      Code   Len   elapsed-time
    +-----+-----+-----+-----+
    |  8  |  2  | t1  | t2  |
    +-----+-----+-----+-----+

  **Relay Message (Option 9)**

  The Relay Message option is used in a RELAY-FORW or RELAY-REPL message to carry
  DHCPv6 messages.

  **DNS Recursive Name Server (Option 23)**

  The DNS Recursive Name Server option provides a list of one or more IPv6
  addresses of DNS recursive name servers.

  The format is:

      Code   Len   IPv6-address-1  IPv6-address-2  ...
    +-----+-----+-----+-----+-----+-----+-----+---
    | 23  |  n  | a1  | a2  | a3  | a4  | a5  | ...
    +-----+-----+-----+-----+-----+-----+-----+---
  """

  @type t :: %__MODULE__{
          option_code: integer(),
          option_data: binary()
        }

  defstruct [
    :option_code,
    :option_data
  ]

  @doc """
  Create a new DHCPv6 option.

  ## Parameters

    * `option_code` - DHCPv6 option code (0-65535)
    * `option_data` - Binary data for the option

  ## Returns

    A new `DHCPv6.Message.Option` struct

  ## Examples

      iex> option = DHCPv6.Message.Option.new(23, <<0x2001, 0x4860, 0x4860::16, 0, 0, 0, 0, 0x8888::16>>)
      iex> option.option_code
      23

  """
  @spec new(non_neg_integer(), binary()) :: t()
  def new(option_code, option_data) do
    %__MODULE__{
      option_code: option_code,
      option_data: option_data
    }
  end

  @doc """
  Parse DHCPv6 option from binary data.

  ## Parameters

    * `data` - Binary data containing DHCPv6 option(s)

  ## Returns

    * `{:ok, option, rest}` - Successfully parsed option and remaining data
    * `{:error, reason}` - Parsing failed

  ## Examples

      iex> {:ok, option, rest} = DHCPv6.Message.Option.parse_option(<<23, 0, 16, 0x2001, 0x4860, 0x4860::16, 0, 0, 0, 0, 0x8888::16>>)
      iex> option.option_code
      23
      iex> byte_size(rest)
      0

  """
  @spec parse_option(binary()) :: {:ok, t(), binary()} | {:error, String.t()}
  def parse_option(
        <<option_code::16, option_length::16, option_data::binary-size(option_length),
          rest::binary>>
      ) do
    {:ok, %__MODULE__{option_code: option_code, option_data: option_data}, rest}
  end

  def parse_option(_), do: {:error, "Invalid DHCPv6 option format"}

  @doc """
  Convert DHCPv6 option to binary.
  """
  @spec to_iodata(t()) :: binary()
  def to_iodata(option) do
    option_length = byte_size(option.option_data)
    <<option.option_code::16, option_length::16, option.option_data::binary>>
  end

  @doc """
  Create IA_NA option (Identity Association for Non-temporary Addresses).

  The IA_NA option is used to carry an IA_NA, the parameters associated with it,
  and the IPv6 addresses associated with it.

  ## Parameters

    * `iaid` - Identity Association Identifier (4 bytes)
    * `t1` - Rebind time in seconds (4 bytes)
    * `t2` - Rebind time in seconds (4 bytes)
    * `addresses` - List of IPv6 addresses to include

  ## Returns

    A new `DHCPv6.Message.Option` struct containing the IA_NA option

  ## Examples

      iex> option = DHCPv6.Message.Option.ia_na(12345, 3600, 7200, [{0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}])
      iex> option.option_code
      3

  """
  @spec ia_na(non_neg_integer(), non_neg_integer(), non_neg_integer(), [:inet.ip6_address()]) ::
          t()
  def ia_na(iaid, t1, t2, addresses) do
    iaid_bin = <<iaid::32>>
    t1_bin = <<t1::32>>
    t2_bin = <<t2::32>>

    iaaddr_options =
      Enum.map(addresses, fn addr ->
        addr_bin = ip6_to_binary(addr)
        # IAADDR option
        iaaddr_opt = new(5, addr_bin)
        to_iodata(iaaddr_opt)
      end)
      |> Enum.join()

    ia_na_data = <<iaid_bin::binary, t1_bin::binary, t2_bin::binary, iaaddr_options::binary>>
    # IA_NA option code
    new(3, ia_na_data)
  end

  @doc """
  Create DNS servers option (Option 23).

  The DNS Recursive Name Server option provides a list of one or more IPv6
  addresses of DNS recursive name servers to be used by the client.

  ## Parameters

    * `servers` - List of IPv6 addresses of DNS servers

  ## Returns

    A new `DHCPv6.Message.Option` struct containing the DNS servers option

  ## Examples

      iex> google_dns = {0x2001, 0x4860, 0x4860, 0, 0, 0, 0, 0x8888}
      iex> option = DHCPv6.Message.Option.dns_servers([google_dns])
      iex> option.option_code
      23

  """
  @spec dns_servers([:inet.ip6_address()]) :: t()
  def dns_servers(servers) do
    server_data = Enum.map(servers, &ip6_to_binary/1) |> Enum.join()
    new(23, server_data)
  end

  defp ip6_to_binary({a, b, c, d, e, f, g, h}) do
    <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>>
  end

  defimpl DHCP.Parameter, for: DHCPv6.Message.Option do
    @impl true
    def to_iodata(%DHCPv6.Message.Option{} = option) do
      option_length = byte_size(option.option_data)
      <<option.option_code::16, option_length::16, option.option_data::binary>>
    end
  end

  defimpl String.Chars, for: DHCPv6.Message.Option do
    def to_string(%DHCPv6.Message.Option{} = option) do
      decoded_value = decode_option_value(option.option_code, option.option_data)
      "Option(#{option.option_code}): #{parse_decoded_value(decoded_value)}\n"
    end

    defp decode_option_value(option_code, option_data) do
      case option_code do
        1 ->
          {"Client Identifier", :binary, option_data}

        2 ->
          {"Server Identifier", :binary, option_data}

        3 ->
          {"IA_NA", :binary, option_data}

        5 ->
          {"IAADDR", :binary, option_data}

        6 ->
          {"Option Request", :binary, option_data}

        7 ->
          {"Preference", :int, option_data}

        8 ->
          {"Elapsed Time", :int, option_data}

        23 ->
          {"DNS Recursive Name Server", :ip6_list, option_data}

        _ ->
          {"Unknown", :raw, option_data}
      end
    end

    defp parse_decoded_value({name, type, value}) do
      case type do
        :ip6_list ->
          servers = parse_ipv6_list(value)
          "#{name}: #{Enum.map(servers, &ip6_to_string/1) |> Enum.join(", ")}"

        :int ->
          <<int_value::16>> = value
          "#{name}: #{int_value}"

        :binary ->
          "#{name}: #{value |> inspect()}"

        :raw ->
          "#{name}: #{value |> inspect()}"
      end
    end

    defp parse_ipv6_list(data) when byte_size(data) < 16, do: []

    defp parse_ipv6_list(data) do
      <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16, rest::binary>> = data
      server = {a, b, c, d, e, f, g, h}
      [server | parse_ipv6_list(rest)]
    end

    defp ip6_to_string({a, b, c, d, e, f, g, h}) do
      :inet.ntoa({a, b, c, d, e, f, g, h})
    end
  end
end
