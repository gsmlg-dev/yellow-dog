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
  alias YellowDog.DNS.Class
  alias YellowDog.DNS.Message.Record
  alias YellowDog.DNS.ResourceRecord.Type, as: RType

  import YellowDog.DNS.Message.NameUtils

  @type t :: %__MODULE__{
          name: String.t()
        }

  defstruct name: ".",
            type: 0,
            class: 0,
            ttl: 0,
            data: <<>>

  def from_buffer(buffer, message \\ <<>>) do
    with {name_length, name} <- name_from_buffer(buffer, message),
         <<_::binary-size(name_length), type::16, class::16, ttl::32, rdlength::16, rest::binary>> <-
           buffer,
         <<rdata::binary-size(rdlength), _rest::binary>> <- rest do
      {name_length + rdlength + 10,
       %Record{
         name: name,
         type: type,
         class: class,
         ttl: ttl,
         data: _rdata_from_message(RType.get_name(type), rdata, message)
       }}
    else
      error ->
        throw({:format_error, error})
    end
  end

  @doc """
    Converts a Record struct to binary data.
  """
  def to_buffer(record = %__MODULE__{}) do
    rdata = _rdata_to_buffer(RType.get_name(record.type), record.data)

    <<name_to_buffer(record.name)::binary, record.type::16, record.class::16, record.ttl::32,
      byte_size(rdata)::16, rdata::binary>>
  end

  def new(name, type, class, ttl, data) do
    new_name = name |> name_to_buffer() |> name_from_buffer() |> elem(1)

    %__MODULE__{name: new_name, type: type, class: class, ttl: ttl, data: data}
  end

  def list_to_buffer(list) when is_list(list) do
    list |> Enum.map(&Record.to_buffer/1) |> Enum.join()
  end

  def list_from_message(count, _message, _offset) when count == 0 do
    {0, []}
  end

  def list_from_message(count, message, offset)
      when count > 0 and is_bitstring(message) and
             byte_size(message) >= offset + count * 11 do
    buffer = binary_part(message, offset, byte_size(message) - offset)

    {size, records} =
      Enum.reduce(1..count, {0, []}, fn _, {offset, rescord_list} ->
        sub_buffer = binary_part(buffer, offset, byte_size(buffer) - offset)
        {size, record} = from_buffer(sub_buffer, message)
        {offset + size, [record | rescord_list]}
      end)

    {size, records |> Enum.reverse()}
  end

  def _rdata_from_message(type, rdata, message \\ <<>>)

  def _rdata_from_message(:a, data, _) do
    <<a::8, b::8, c::8, d::8>> = data
    {a, b, c, d}
  end

  def _rdata_from_message(:aaaa, data, _) do
    <<a0::8, b0::8, c0::8, d0::8, a1::8, b1::8, c1::8, d1::8, a2::8, b2::8, c2::8, d2::8, a3::8,
      b3::8, c3::8, d3::8>> = data

    {a0, b0, c0, d0, a1, b1, c1, d1, a2, b2, c2, d2, a3, b3, c3, d3}
  end

  def _rdata_from_message(type, data, message) when type in [:cname, :ns, :ptr, :dname] do
    name_from_buffer(data, message) |> elem(1)
  end

  def _rdata_from_message(:mx, <<weight::16, data>>, message) do
    {weight, name_from_buffer(data, message)}
  end

  def _rdata_from_message(:soa, data, message) do
    {ns_len, ns} = name_from_buffer(data, message)

    {rp_len, rp} =
      name_from_buffer(binary_part(data, ns_len, byte_size(data) - ns_len), message)

    <<serial::32, refresh::32, retry::32, expire::32, negative::32>> =
      binary_part(data, ns_len + rp_len, byte_size(data) - ns_len - rp_len)

    {ns, rp, serial, refresh, retry, expire, negative}
  end

  def _rdata_from_message(:srv, <<priority::16, weight::16, port::16, data::binary>>, message) do
    {priority, weight, port, name_from_buffer(data, message) |> elem(1)}
  end

  def _rdata_from_message(:txt, <<len::8, data>>, _) do
    case data do
      <<section::binary-size(len), next_len::8, next::binary>> ->
        [section] ++ _rdata_from_message(:txt, <<next_len::8, next::binary>>)

      <<section::binary-size(len)>> ->
        [section]
    end
  end

  def _rdata_from_message(type, data, _) when is_atom(type) do
    data
  end
  def _rdata_from_message({type, type_code}, data, _) when is_atom(type) and is_integer(type_code) do
    data
  end


  def _rdata_to_buffer(:a, {a, b, c, d}) do
    <<a::8, b::8, c::8, d::8>>
  end

  def _rdata_to_buffer(:aaaa, {a0, b0, c0, d0, a1, b1, c1, d1, a2, b2, c2, d2, a3, b3, c3, d3}) do
    <<a0::8, b0::8, c0::8, d0::8, a1::8, b1::8, c1::8, d1::8, a2::8, b2::8, c2::8, d2::8, a3::8,
      b3::8, c3::8, d3::8>>
  end

  def _rdata_to_buffer(type, data) when type in [:cname, :ns, :ptr, :dname] do
    name_to_buffer(data)
  end

  def _rdata_to_buffer(:mx, {weight, data}) do
    <<weight::16, data>>
  end

  def _rdata_to_buffer(:soa, {ns, rp, serial, refresh, retry, expire, negative}) do
    <<name_to_buffer(ns)::binary, name_to_buffer(rp)::binary, serial::32, refresh::32, retry::32,
      expire::32, negative::32>>
  end

  def _rdata_to_buffer(:srv, {priority, weight, port, data}) do
    <<priority::16, weight::16, port::16, name_to_buffer(data)::binary>>
  end

  def _rdata_to_buffer(:txt, data) do
    for section <- data do
      <<byte_size(section), section::binary>>
    end
    |> Enum.join(<<>>)
  end

  def _rdata_to_buffer(type, data) when is_atom(type) do
    data
  end

  def to_print(r = %__MODULE__{type: type}) do
    case RType.get_name(type) do
      t when t == :a or t == :aaaa ->
        "#{r.name} #{r.ttl} #{r.class |> Class.to_print()} #{r.type |> RType.get_name()} #{YellowDog.Utils.a2s(r.data)}"

      t when t in [:cname, :ns, :ptr, :dname] ->
        "#{r.name} #{r.ttl} #{r.class |> Class.to_print()} #{r.type |> RType.get_name()} #{r.data}"

      t when t in [:mx, :soa, :srv] ->
        "#{r.name} #{r.ttl} #{r.class |> Class.to_print()} #{r.type |> RType.get_name()} #{r.data |> print_tuple()}"

      :txt ->
        "#{r.name} #{r.ttl} #{r.class |> Class.to_print()} #{r.type |> RType.get_name()} #{r.data |> Enum.map(&inspect/1) |> Enum.join(" ")}"

      t ->
        "#{r.name} #{r.ttl} #{r.class |> Class.to_print()} #{t} #{inspect(r.data)}"
    end
  end

  defp print_tuple(t) do
    t |> Tuple.to_list() |> Enum.map(&"#{&1}") |> Enum.join(" ")
  end
end
