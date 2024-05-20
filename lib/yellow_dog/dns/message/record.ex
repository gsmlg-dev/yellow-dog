defmodule YellowDog.DNS.Message.Record do
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
  alias YellowDog.DNS.Message
  alias YellowDog.DNS.Message.Record

  @type t :: %__MODULE__{
          name: String.t()
        }

  defstruct name: ".",
            type: 0,
            class: 0,
            ttl: 0,
            data: <<>>

  def from_buffer(buffer, message \\ <<>>) do
    with {name_length, name} = Message.name_from_buffer(buffer, message),
         <<_::binary-size(name_length), type::16, class::16, ttl::32, rdlength::16, rest::binary>> =
           buffer,
         <<rdata::binary-size(rdlength), _rest::binary>> = rest do
      {name_length + rdlength + 10,
       %Record{name: name, type: type, class: class, ttl: ttl, data: rdata}}
    end
  end

  @doc """
    Converts a Record struct to binary data.
  """
  def to_buffer(record = %__MODULE__{}) do
    # TODO: Implement this function
  end

  @spec list_to_buffer(maybe_improper_list()) :: binary()
  def list_to_buffer(list) when is_list(list) do
    list |> Enum.map(&Record.to_buffer/1) |> IO.iodata_to_binary()
  end

  @spec list_from_message(any(), any(), any()) :: nil | {0, []}
  def list_from_message(count, _message, _offset) when count == 0 do
    {0, []}
  end

  def list_from_message(count, message, offset) when count > 0 do
    buffer = binary_part(message, offset, byte_size(message) - offset)

    {size, records} =
      Enum.reduce(1..count, {0, []}, fn _, {offset, rescord_list} ->
        {size, record} =
          from_buffer(binary_part(buffer, offset, byte_size(buffer) - offset), message)

        {offset + size, [record | rescord_list]}
      end)

    {size, records |> Enum.reverse()}
  end
end
