defprotocol DHCP.Parameter do
  @moduledoc """
  Protocol for converting DHCP data structures to binary format.

  This protocol defines a unified interface for serializing DHCP messages
  and options to their binary wire format. All DHCP-related structs should
  implement this protocol to ensure consistent serialization behavior.

  ## Implementation

  To implement this protocol for your custom DHCP-related struct:

      defimpl DHCP.Parameter, for: MyStruct do
        @impl true
        def to_iodata(%MyStruct{} = struct) do
          # Convert struct to binary format
          <<binary_data>>
        end
      end

  ## Built-in Implementations

  The following structs implement this protocol by default:

  - `DHCPv4.Message` - DHCPv4 message serialization
  - `DHCPv4.Message.Option` - DHCPv4 option serialization
  - `DHCPv6.Message` - DHCPv6 message serialization
  - `DHCPv6.Message.Option` - DHCPv6 option serialization

  ## Usage

      iex> message = DHCPv4.Message.new()
      iex> binary = DHCP.Parameter.to_iodata(message)
      iex> is_binary(binary)
      true

  """

  @doc """
  Convert a DHCP data structure to binary format.

  This function should return the binary representation of the DHCP data
  suitable for network transmission.

  ## Parameters

    * `value` - The DHCP data structure to convert

  ## Returns

    Binary representation of the DHCP data

  """
  @spec to_iodata(t()) :: binary()
  def to_iodata(value)
end
