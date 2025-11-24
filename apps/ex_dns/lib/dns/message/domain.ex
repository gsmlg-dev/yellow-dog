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

  @max_compression_depth DNS.Constants.max_compression_depth()

  @doc """
  Get name from bitstring, uncompress name in message
  """
  def from_iodata(bitstring, dns_message \\ <<>>) do
    {len, domain} = parse_domain_from_message(bitstring, dns_message, 0, MapSet.new())
    new(domain, len)
  end

  defp parse_domain_from_message(<<size::8, _::binary>>, _, _depth, _visited) when size == 0,
    do: {1, "."}

  defp parse_domain_from_message(_buffer, _message, depth, _visited)
       when depth > @max_compression_depth do
    Error.log_detailed_error(:compression_error, __MODULE__, %{
      depth: depth,
      max_depth: @max_compression_depth
    })

    throw(Error.new(:compression_error, __MODULE__, :depth_exceeded, %{depth: depth}))
  end

  defp parse_domain_from_message(<<pointer::2, pos::14, rest::binary>>, message, depth, visited)
       when pointer == 0b11 do
    # Check for compression loop detection
    _current_pos = byte_size(message) - byte_size(rest) - 2

    if MapSet.member?(visited, pos) do
      Error.log_detailed_error(:compression_error, __MODULE__, %{
        loop_position: pos,
        visited_positions: MapSet.to_list(visited)
      })

      throw(Error.new(:compression_error, __MODULE__, :loop_detected, %{position: pos}))
    end

    updated_visited = MapSet.put(visited, pos)

    case message do
      <<_::binary-size(pos), next::8, next_buffer::binary>> when next > 0 and next < 64 ->
        {_, name} =
          parse_domain_from_message(
            <<next::8, next_buffer::binary>>,
            message,
            depth + 1,
            updated_visited
          )

        {2, name}

      <<_::binary-size(pos), next_pointer::2, next_pos::14, next_buffer::binary>>
      when next_pointer == 0b11 and pos != next_pos ->
        {_, name} =
          parse_domain_from_message(
            <<next_pointer::2, next_pos::8, next_buffer::binary>>,
            message,
            depth + 1,
            updated_visited
          )

        {2, name}

      _ ->
        Error.log_detailed_error(:format_error, __MODULE__, %{pointer: pointer, position: pos})
        throw(Error.new(:format_error, __MODULE__, :invalid_pointer))
    end
  end

  defp parse_domain_from_message(<<size::8, rest::binary>>, message, depth, visited)
       when size > 0 and size < 64 do
    case rest do
      <<part::binary-size(size), next::8, _::binary>> when next == 0 ->
        {1 + size + 1, part <> "."}

      <<part::binary-size(size), next::8, next_pos::8, last_buffer::binary>> when next == 0xC0 ->
        {_, compressed_name} =
          parse_domain_from_message(
            <<next::8, next_pos::8, last_buffer::binary>>,
            message,
            depth + 1,
            visited
          )

        {1 + size + 2, part <> "." <> compressed_name}

      <<part::binary-size(size), next::8, next_buffer::binary>> when next > 0 and next < 64 ->
        {last_size, last_name} =
          parse_domain_from_message(<<next::8, next_buffer::binary>>, message, depth + 1, visited)

        {1 + size + last_size, part <> "." <> last_name}

      <<_::binary-size(size), _::binary>> ->
        Error.log_detailed_error(:format_error, __MODULE__, %{size: size})
        throw(Error.new(:format_error, __MODULE__, :invalid_domain_part))
    end
  end

  defp parse_domain_from_message(buffer, _message, _depth, _visited) do
    Error.log_detailed_error(:format_error, __MODULE__, %{buffer_size: byte_size(buffer)})
    throw(Error.new(:format_error, __MODULE__, :invalid_format))
  end

  defp domain_byte_size(domain) do
    case String.split(domain, ".") |> Enum.filter(&(&1 != "")) do
      [] ->
        <<0>>

      list ->
        list
        |> Enum.reverse()
        |> Enum.reduce(<<0>>, fn part, acc ->
          part_length = byte_size(part)
          <<part_length::8, part::binary-size(part_length), acc::binary>>
        end)
    end
    |> byte_size()
  end

  defimpl DNS.Parameter, for: Domain do
    @impl true
    def to_iodata(%Domain{value: domain}) do
      case String.split(domain, ".") |> Enum.filter(&(&1 != "")) do
        [] ->
          <<0>>

        list ->
          list
          |> Enum.reverse()
          |> Enum.reduce(<<0>>, fn part, acc ->
            part_length = byte_size(part)
            <<part_length::8, part::binary-size(part_length), acc::binary>>
          end)
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
