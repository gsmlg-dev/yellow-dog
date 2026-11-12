defmodule DNS.Message.Domain do
  @moduledoc """
  # DNS Domain

  """
  alias DNS.Message.Domain
  alias DNS.Error

  @type t :: %__MODULE__{
          size: non_neg_integer(),
          value: binary()
        }

  defstruct value: ".", size: 1

  @spec new(binary(), non_neg_integer()) :: Domain.t()
  def new(value, length) do
    %Domain{
      value: value,
      size: length
    }
  end

  @spec new(binary()) :: Domain.t()
  def new(value) do
    value =
      if String.last(value) == "." do
        value
      else
        value <> "."
      end

    %Domain{
      value: value,
      size: domain_byte_size(value)
    }
  end

  # RFC 1035 §3.1/§4.1.4: a name is at most 255 octets on the wire; a pointer is
  # any byte whose top two bits are 11, followed by a 14-bit message offset.
  @max_name_octets 255
  @max_pointer_hops DNS.Constants.max_compression_pointers()

  @doc """
  Get name from bitstring, uncompress name in message.

  `bitstring` starts at the name; `dns_message` is the whole message that
  compression pointers index into. The returned `size` is the number of octets
  the name occupies in `bitstring` (up to and including the first pointer).
  """
  def from_iodata(bitstring, dns_message \\ <<>>) do
    {size, labels} = walk(bitstring, dns_message, 0, false, [], 1, MapSet.new())

    value =
      case labels do
        [] -> "."
        _ -> labels |> Enum.reverse() |> Enum.join(".") |> Kernel.<>(".")
      end

    new(value, size)
  end

  # walk(bin, message, size, jumped?, labels, wire_octets, visited_offsets)
  defp walk(<<0, _::binary>>, _message, size, jumped, labels, _octets, _visited),
    do: {if(jumped, do: size, else: size + 1), labels}

  defp walk(<<0b11::2, offset::14, _::binary>>, message, size, jumped, labels, octets, visited) do
    cond do
      MapSet.member?(visited, offset) ->
        fail(:format_error, :loop_detected, %{position: offset})

      MapSet.size(visited) >= @max_pointer_hops ->
        fail(:compression_error, :depth_exceeded, %{depth: MapSet.size(visited) + 1})

      offset >= byte_size(message) ->
        fail(:format_error, :invalid_pointer, %{position: offset})

      true ->
        <<_::binary-size(offset), target::binary>> = message
        size = if jumped, do: size, else: size + 2
        walk(target, message, size, true, labels, octets, MapSet.put(visited, offset))
    end
  end

  defp walk(
         <<0b00::2, len::6, label::binary-size(len), rest::binary>>,
         message,
         size,
         jumped,
         labels,
         octets,
         visited
       ) do
    octets = octets + 1 + len

    if octets > @max_name_octets do
      fail(:format_error, :name_too_long, %{octets: octets})
    end

    size = if jumped, do: size, else: size + 1 + len
    walk(rest, message, size, jumped, [label | labels], octets, visited)
  end

  defp walk(buffer, _message, _size, _jumped, _labels, _octets, _visited),
    do: fail(:format_error, :invalid_format, %{buffer_size: byte_size(buffer)})

  defp fail(type, reason, context) do
    Error.log_detailed_error(type, __MODULE__, Map.put(context, :reason, reason))
    throw(Error.new(type, __MODULE__, reason, context))
  end

  defp domain_byte_size(domain) do
    case String.split(domain, ".", trim: true) do
      [] ->
        <<0>>

      list ->
        Enum.map_join(list, fn part ->
          <<byte_size(part)::8, part::binary>>
        end) <> <<0>>
    end
    |> byte_size()
  end

  defimpl DNS.Parameter, for: Domain do
    @impl true
    def to_iodata(%Domain{value: domain}) do
      case String.split(domain, ".", trim: true) do
        [] ->
          <<0>>

        list ->
          Enum.map_join(list, fn part ->
            <<byte_size(part)::8, part::binary>>
          end) <> <<0>>
      end
    end
  end

  defimpl String.Chars, for: Domain do
    @impl true
    @spec to_string(Domain.t()) :: binary()
    def to_string(domain) do
      domain.value
    end
  end

  defimpl Inspect, for: Domain do
    import Inspect.Algebra

    @impl true
    def inspect(domain, _opts) do
      concat(["#DNS.Domain<", domain.value, ">"])
    end
  end
end
