defmodule DHCPv4.Message.Option do
  @moduledoc """
  DHCPv4 option handling with clear separation of concerns.

  This module provides a unified interface for DHCPv4 option operations
  while delegating to specialized modules for specific functionality:

  - `DHCPv4.Message.Option.Types` - Type-specific option decoding
  - `DHCPv4.Message.Option.Decoder` - Option parsing logic
  - `DHCPv4.Message.Option.Serializer` - Option serialization
  - `DHCPv4.Message.Option.Formatter` - Option display formatting
  - `DHCPv4.Message.Option.Helpers` - Common utility functions

  ## Examples

      iex> DHCPv4.Message.Option.parse(data)
      [%{type: 1, length: 4, value: <<255, 255, 255, 0>>}]

      iex> DHCPv4.Message.Option.decode_option_value(1, 4, <<255, 255, 255, 0>>)
      {"Subnet Mask", :ip, {255, 255, 255, 0}}

  """

  alias DHCPv4.Message.Option.{Decoder, Serializer, Formatter, Helpers}

  @type t :: %__MODULE__{
          type: 0..255,
          length: 0..255,
          value: bitstring()
        }

  defstruct type: nil, length: nil, value: nil

  # Delegate to helper functions
  defdelegate new(type, length, value), to: Helpers
  defdelegate from_iodata(data), to: Helpers

  # Delegate to decoder functions
  def parse(data), do: Decoder.parse(data)

  @doc """
  Parse DHCP options, raising on errors (backward compatibility).
  """
  @spec parse!(binary()) :: [t()]
  def parse!(data) do
    case parse(data) do
      {:ok, options} -> options
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  # Delegate to decoder functions
  defdelegate decode_option_value(type, length, value), to: Decoder

  # Delegate to serializer functions
  defdelegate to_dhcp_binary(options), to: Serializer

  # Implement DHCP.Parameter protocol
  defimpl DHCP.Parameter, for: __MODULE__ do
    @impl true
    def to_iodata(%DHCPv4.Message.Option{} = option) do
      Helpers.to_iodata(option)
    end
  end

  # Implement String.Chars protocol
  defimpl String.Chars, for: __MODULE__ do
    def to_string(%DHCPv4.Message.Option{} = option) do
      Formatter.format(option)
    end
  end
end
