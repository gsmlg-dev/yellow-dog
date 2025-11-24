defmodule DNS.Message.Record.Data do
  @moduledoc """
  Generic DNS resource record data module.

  This module provides a fallback implementation for DNS resource record data
  when specific record type modules are not available. It serves as a generic
  container for raw record data and delegates to specialized modules when possible.

  ## Registry Integration

  The module integrates with `DNS.Message.Record.Data.Registry` to find appropriate
  record type implementations. When a specific type is found, it delegates to that
  module. When no specific implementation exists, it stores the raw data.

  ## Fields

  * `type` - Resource record type information
  * `rdlength` - Length of the RDATA field (0-65535)
  * `raw` - Raw binary data for the record

  ## Examples

      # When specific type is available
      iex> rtype = DNS.ResourceRecordType.new(1)  # A record
      iex> data = DNS.Message.Record.Data.new(rtype, {192, 168, 1, 1})
      iex> %DNS.Message.Record.Data.A{} = data

      # When type is unknown, falls back to generic storage
      iex> rtype = DNS.ResourceRecordType.new(9999)  # Unknown type
      iex> data = DNS.Message.Record.Data.new(rtype, "custom_data")
      iex> %DNS.Message.Record.Data{raw: "custom_data"} = data
  """

  alias DNS.ResourceRecordType, as: RRType
  alias DNS.Message.Record.Data.Registry

  @type t :: %__MODULE__{
          type: DNS.ResourceRecordType.t(),
          rdlength: 0..65535,
          raw: bitstring()
        }

  defstruct raw: <<>>, type: nil, rdlength: nil

  @doc """
  Create a new record data instance.

  Attempts to find a specific implementation for the record type in the registry.
  If found, delegates to that module. Otherwise, creates a generic data container.

  ## Parameters

  * `rtype` - Resource record type struct containing type information
  * `rdata` - Raw record data (format depends on record type)

  ## Returns

  * Record data struct (specific type if available, generic otherwise)

  ## Examples

      iex> rtype = DNS.ResourceRecordType.new(1)  # A record
      iex> data = DNS.Message.Record.Data.new(rtype, {192, 168, 1, 1})
      iex> %DNS.Message.Record.Data.A{} = data
  """
  @spec new(RRType.t(), term()) :: term()
  def new(%RRType{value: <<type::16>>} = rtype, rdata) do
    case Registry.lookup(type) do
      {:ok, module} ->
        module.new(rdata)

      {:error, :not_found} ->
        # Fallback to generic data storage for unknown types
        %__MODULE__{type: rtype, rdlength: byte_size(rdata), raw: rdata}
    end
  end

  @doc """
  Parse record data from binary iodata.

  Attempts to find a specific implementation for the record type in the registry.
  If found, delegates to that module's `from_iodata/2` function. Otherwise,
  creates a generic data container with the raw bytes.

  ## Parameters

  * `type` - DNS record type number (integer)
  * `raw` - Binary data for the record
  * `message` - Full DNS message (used by some record types for context)

  ## Returns

  * Record data struct (specific type if available, generic otherwise)

  ## Examples

      iex> data = DNS.Message.Record.Data.from_iodata(1, <<192, 168, 1, 1>>)
      iex> %DNS.Message.Record.Data.A{} = data
  """
  @spec from_iodata(non_neg_integer(), iodata(), binary()) :: term()
  def from_iodata(type, raw, message \\ <<>>) do
    case Registry.lookup(type) do
      {:ok, module} ->
        module.from_iodata(raw, message)

      {:error, :not_found} ->
        # Fallback to generic data storage for unknown types
        %__MODULE__{type: DNS.ResourceRecordType.new(type), rdlength: byte_size(raw), raw: raw}
    end
  end

  defimpl DNS.Parameter, for: DNS.Message.Record.Data do
    @moduledoc """
    Implementation of DNS.Parameter for generic record data.

    Serializes generic record data by prefixing with the RDLENGTH field followed
    by the raw binary data.
    """

    @impl true
    @doc """
    Convert generic record data to DNS protocol binary format.

    The output includes the RDLENGTH field (2 bytes) followed by the raw data.

    ## Examples

        iex> data = %DNS.Message.Record.Data{rdlength: 4, raw: <<192, 168, 1, 1>>}
        iex> DNS.Parameter.to_iodata(data)
        <<0, 4, 192, 168, 1, 1>>
    """
    @spec to_iodata(DNS.Message.Record.Data.t()) :: binary()
    def to_iodata(%DNS.Message.Record.Data{} = data) do
      <<data.rdlength::16>> <> data.raw
    end
  end

  defimpl String.Chars, for: DNS.Message.Record.Data do
    @moduledoc """
    Implementation of String.Chars for generic record data.

    Provides a string representation by inspecting the raw binary data.
    """

    @doc """
    Convert generic record data to a string representation.

    Uses `inspect/1` on the raw binary data to provide a readable representation.

    ## Examples

        iex> data = %DNS.Message.Record.Data{raw: <<192, 168, 1, 1>>}
        iex> to_string(data)
        "<<192, 168, 1, 1>>"
    """
    @spec to_string(DNS.Message.Record.Data.t()) :: String.t()
    def to_string(record) do
      record.raw |> inspect()
    end
  end
end
