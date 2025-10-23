defmodule DNS.Message.Record do
  @moduledoc """
    Record is a struct that represents a DNS resource record.

    All RRs have the same top level format shown below:

    ```txt
                                        1  1  1  1  1  1
          0  1  2  3  4  5  6  7  8  9  0  1  2  3  4  5
        +--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+
        |                                               |
        /                                               /
        /                      NAME                     /
        |                                               |
        +--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+
        |                      TYPE                     |
        +--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+
        |                     CLASS                     |
        +--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+
        |                      TTL                      |
        |                                               |
        +--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+
        |                   RDLENGTH                    |
        +--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--|
        /                     RDATA                     /
        /                                               /
        +--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+
    ```

    where:

    NAME            an owner name, i.e., the name of the node to which this
                    resource record pertains.

    TYPE            two octets containing one of the RR TYPE codes.

    CLASS           two octets containing one of the RR CLASS codes.

    TTL             a 32 bit signed integer that specifies the time interval
                    that the resource record may be cached before the source
                    of the information should again be consulted.  Zero
                    values are interpreted to mean that the RR can only be
                    used for the transaction in progress, and should not be
                    cached.  For example, SOA records are always distributed
                    with a zero TTL to prohibit caching.  Zero values can
                    also be used for extremely volatile data.

    RDLENGTH        an unsigned 16 bit integer that specifies the length in
                    octets of the RDATA field.

    RDATA           a variable length string of octets that describes the
                    resource.  The format of this information varies
                    according to the TYPE and CLASS of the resource record.
  """

  @max_rdlength DNS.Constants.max_rdlength()
  alias DNS.Class
  alias DNS.Message.Domain
  alias DNS.Message.Record
  alias DNS.ResourceRecordType, as: RRType
  alias DNS.Message.Record.Data, as: RData
  alias DNS.Error

  @type t :: %__MODULE__{
          name: Domain.t(),
          type: RRType.t(),
          class: Class.t(),
          ttl: 0..4_294_967_295,
          rdlength: 0..65535,
          data: RData.t()
        }

  defstruct name: Domain.new("."),
            type: RRType.new(1),
            class: Class.new(1),
            ttl: 0,
            rdlength: nil,
            data: RData.new(RRType.new(1), {0, 0, 0, 0})

  def new(name, type, class, ttl, data) do
    domain = Domain.new(name)
    rtype = RRType.new(type)
    rclass = Class.new(class)
    rdata = RData.new(rtype, data)

    %__MODULE__{
      name: domain,
      type: rtype,
      class: rclass,
      ttl: ttl,
      rdlength: rdata.rdlength,
      data: rdata
    }
  end

  def from_iodata(buffer, message \\ <<>>) do
    with domain <- Domain.from_iodata(buffer, message),
         <<_::binary-size(domain.size), type::16, class::16, ttl::32, rdlength::16, rest::binary>> <-
           buffer do
      # Validate rdlength to prevent memory exhaustion attacks
      if rdlength > @max_rdlength do
        Error.log_detailed_error(:security_error, __MODULE__, %{
          rdlength: rdlength,
          max_rdlength: @max_rdlength
        })

        throw(Error.new(:security_error, __MODULE__, :rdlength_too_large, %{rdlength: rdlength}))
      end

      case rest do
        <<rdata::binary-size(rdlength), _::binary>> ->
          rtype = RRType.new(<<type::16>>)

          %Record{
            name: domain,
            type: rtype,
            class: Class.new(class),
            ttl: ttl,
            rdlength: rdlength,
            data: RData.from_iodata(type, rdata, message)
          }

        _ ->
          Error.log_detailed_error(:format_error, __MODULE__, %{
            rdlength: rdlength,
            rest_size: byte_size(rest)
          })

          throw(Error.new(:format_error, __MODULE__, :insufficient_rdata))
      end
    else
      error ->
        Error.log_detailed_error(:format_error, __MODULE__, %{parse_error: error})
        throw(Error.new(:format_error, __MODULE__, :parse_failed))
    end
  end

  def list_from_message(0, _message, offset), do: {[], offset}

  def list_from_message(count, message, offset) do
    {record_list, end_offset} =
      Enum.reduce(1..count, {[], offset}, fn _, {records, offset} ->
        <<_::binary-size(offset), buffer::binary>> = message
        record = from_iodata(buffer, message)

        {[record | records], offset + record.name.size + 2 + 2 + 4 + 2 + record.rdlength}
      end)

    {record_list, end_offset}
  end

  defimpl DNS.Parameter, for: DNS.Message.Record do
    @impl true
    def to_iodata(%DNS.Message.Record{} = record) do
      DNS.to_iodata(record.name) <>
        DNS.to_iodata(record.type) <>
        DNS.to_iodata(record.class) <>
        <<record.ttl::32>> <> DNS.to_iodata(record.data)
    end
  end

  defimpl String.Chars, for: DNS.Message.Record do
    def to_string(record) do
      "#{record.name} #{record.type} #{record.class} #{record.ttl} #{record.data}"
    end
  end
end
