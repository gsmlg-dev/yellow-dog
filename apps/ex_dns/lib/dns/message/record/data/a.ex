defmodule DNS.Message.Record.Data.A do
  @moduledoc """
  DNS A (Address) record implementation.

  A records are used to map domain names to IPv4 addresses. This module provides
  functionality for creating, parsing, and serializing A records according to RFC 1035.

  ## Fields

  * `type` - Resource record type (always 1 for A records)
  * `rdlength` - Length of the RDATA field (always 4 bytes for IPv4 addresses)
  * `raw` - Raw binary data for the record
  * `data` - IPv4 address as a 4-tuple `{a, b, c, d}`

  ## Examples

      iex> record = DNS.Message.Record.Data.A.new({192, 168, 1, 1})
      iex> record.data
      {192, 168, 1, 1}

      iex> raw = <<192, 168, 1, 1>>
      iex> record = DNS.Message.Record.Data.A.from_iodata(raw)
      iex> to_string(record)
      "192.168.1.1"
  """

  @type t :: %__MODULE__{
          type: DNS.ResourceRecordType.t(),
          rdlength: 4,
          raw: bitstring(),
          data: :inet.ip4_address()
        }

  defstruct raw: nil, type: DNS.ResourceRecordType.new(1), rdlength: 4, data: nil

  @doc """
  Create a new A record from an IPv4 address tuple.

  ## Parameters

  * `ip` - IPv4 address as a 4-tuple `{a, b, c, d}` where each element is 0-255

  ## Returns

  * `t()` - A record struct with the IP address data

  ## Examples

      iex> record = DNS.Message.Record.Data.A.new({192, 168, 1, 1})
      iex> record.data
      {192, 168, 1, 1}
  """
  @spec new(:inet.ip4_address()) :: t()
  def new({a, b, c, d} = ip) when a in 0..255 and b in 0..255 and c in 0..255 and d in 0..255 do
    raw = <<a::8, b::8, c::8, d::8>>
    %__MODULE__{raw: raw, data: ip}
  end

  @doc """
  Parse A record data from binary iodata.

  ## Parameters

  * `raw` - Binary data containing the IPv4 address (4 bytes)
  * `message` - Full DNS message (unused for A records, kept for interface consistency)

  ## Returns

  * `t()` - A record struct with parsed IPv4 address

  ## Examples

      iex> record = DNS.Message.Record.Data.A.from_iodata(<<192, 168, 1, 1>>)
      iex> record.data
      {192, 168, 1, 1}
  """
  @spec from_iodata(iodata(), binary()) :: t()
  def from_iodata(raw, _message \\ nil) when is_binary(raw) and byte_size(raw) == 4 do
    <<a::8, b::8, c::8, d::8>> = raw
    %__MODULE__{raw: raw, data: {a, b, c, d}}
  end

  defimpl DNS.Parameter, for: DNS.Message.Record.Data.A do
    @impl true
    def to_iodata(%DNS.Message.Record.Data.A{data: data}) do
      {a, b, c, d} = data
      <<4::16, a::8, b::8, c::8, d::8>>
    end
  end

  defimpl String.Chars, for: DNS.Message.Record.Data.A do
    @moduledoc """
    Implementation of String.Chars for A records.

    Provides human-readable string representation of IPv4 addresses.
    """

    @doc """
    Convert an A record to a human-readable string.

    Uses Erlang's `:inet.ntoa/1` to convert the IPv4 address tuple to a string.
    If conversion fails, falls back to inspecting the raw binary data.

    ## Examples

        iex> record = DNS.Message.Record.Data.A.new({192, 168, 1, 1})
        iex> to_string(record)
        "192.168.1.1"
    """
    @spec to_string(DNS.Message.Record.Data.A.t()) :: String.t()
    def to_string(%DNS.Message.Record.Data.A{data: data, raw: raw}) do
      case data |> :inet.ntoa() do
        ip when is_list(ip) -> "#{ip}"
        _ -> raw |> inspect()
      end
    end
  end
end
