defmodule YellowDog.Netboot.TFTP.Protocol do
  @moduledoc """
  TFTP packet encode/decode per RFC 1350 with RFC 2347 option extension.

  Packet types:
  - RRQ (1):  opcode | filename | 0 | mode | 0 [| option | 0 | value | 0]*
  - WRQ (2):  opcode | filename | 0 | mode | 0 [| option | 0 | value | 0]*
  - DATA (3): opcode | block# | data
  - ACK (4):  opcode | block#
  - ERROR (5): opcode | error_code | error_msg | 0
  - OACK (6): [option | 0 | value | 0]*
  """

  @opcode_rrq 1
  @opcode_wrq 2
  @opcode_data 3
  @opcode_ack 4
  @opcode_error 5
  @opcode_oack 6

  @default_block_size 512

  @error_codes %{
    0 => "Not defined",
    1 => "File not found",
    2 => "Access violation",
    3 => "Disk full or allocation exceeded",
    4 => "Illegal TFTP operation",
    5 => "Unknown transfer ID",
    6 => "File already exists",
    7 => "No such user"
  }

  @type packet ::
          {:rrq, filename :: String.t(), mode :: String.t(), opts :: map()}
          | {:wrq, filename :: String.t(), mode :: String.t(), opts :: map()}
          | {:data, block :: non_neg_integer(), data :: binary()}
          | {:ack, block :: non_neg_integer()}
          | {:error, code :: non_neg_integer(), message :: String.t()}
          | {:oack, opts :: map()}

  @doc "Decode a raw TFTP packet binary into a structured tuple."
  @spec decode(binary()) :: {:ok, packet()} | {:error, :invalid_packet}
  def decode(<<@opcode_rrq::16, rest::binary>>) do
    decode_request(:rrq, rest)
  end

  def decode(<<@opcode_wrq::16, rest::binary>>) do
    decode_request(:wrq, rest)
  end

  def decode(<<@opcode_data::16, block::16, data::binary>>) do
    {:ok, {:data, block, data}}
  end

  def decode(<<@opcode_ack::16, block::16>>) do
    {:ok, {:ack, block}}
  end

  def decode(<<@opcode_error::16, code::16, rest::binary>>) do
    case extract_string(rest) do
      {message, _} -> {:ok, {:error, code, message}}
      :error -> {:error, :invalid_packet}
    end
  end

  def decode(<<@opcode_oack::16, rest::binary>>) do
    case decode_options(rest) do
      {:ok, opts} -> {:ok, {:oack, opts}}
      :error -> {:error, :invalid_packet}
    end
  end

  def decode(_), do: {:error, :invalid_packet}

  @doc "Encode a TFTP packet tuple into binary."
  @spec encode(packet()) :: binary()
  def encode({:data, block, data}) do
    <<@opcode_data::16, block::16, data::binary>>
  end

  def encode({:ack, block}) do
    <<@opcode_ack::16, block::16>>
  end

  def encode({:error, code, message}) do
    <<@opcode_error::16, code::16, message::binary, 0>>
  end

  def encode({:oack, opts}) do
    opts_binary =
      Enum.reduce(opts, <<>>, fn {key, value}, acc ->
        <<acc::binary, to_string(key)::binary, 0, to_string(value)::binary, 0>>
      end)

    <<@opcode_oack::16, opts_binary::binary>>
  end

  @doc "Build an error packet for a given error code."
  @spec error_packet(non_neg_integer()) :: binary()
  def error_packet(code) do
    message = Map.get(@error_codes, code, "Unknown error")
    encode({:error, code, message})
  end

  @doc "Return the default TFTP block size (512 bytes)."
  @spec default_block_size() :: non_neg_integer()
  def default_block_size, do: @default_block_size

  # --- Private helpers ---

  defp decode_request(type, binary) do
    with {filename, rest} when filename != "" <- extract_string(binary),
         {mode, rest} <- extract_string(rest) do
      mode = String.downcase(mode)

      case decode_options(rest) do
        {:ok, opts} -> {:ok, {type, filename, mode, opts}}
        :error -> {:error, :invalid_packet}
      end
    else
      _ -> {:error, :invalid_packet}
    end
  end

  defp extract_string(binary) do
    case :binary.split(binary, <<0>>) do
      [str, rest] -> {str, rest}
      _ -> :error
    end
  end

  defp decode_options(<<>>), do: {:ok, %{}}

  defp decode_options(binary) do
    decode_options(binary, %{})
  end

  defp decode_options(<<>>, acc), do: {:ok, acc}

  defp decode_options(binary, acc) do
    with {key, rest} when key != "" <- extract_string(binary),
         {value, rest} <- extract_string(rest) do
      decode_options(rest, Map.put(acc, String.downcase(key), value))
    else
      _ -> :error
    end
  end
end
