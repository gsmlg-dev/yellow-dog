defmodule DNS.Message.Record.Data.TXT do
  @type t :: %__MODULE__{
          type: DNS.ResourceRecordType.t(),
          rdlength: 1..65535,
          raw: bitstring(),
          data: [binary()]
        }

  defstruct raw: nil, type: DNS.ResourceRecordType.new(16), rdlength: nil, data: nil

  def new(text) do
    raw = Enum.reduce(text, <<>>, fn x, acc -> <<acc::binary, byte_size(x)::8, x::binary>> end)
    %__MODULE__{raw: raw, data: text, rdlength: byte_size(raw)}
  end

  def from_iodata(raw, _message \\ nil) do
    data = parse_raw(raw)
    %__MODULE__{raw: raw, data: data, rdlength: byte_size(raw)}
  end

  defp parse_raw(<<>>), do: []
  defp parse_raw(<<0, rest::binary>>), do: ["" | parse_raw(rest)]

  defp parse_raw(<<length::8, data::binary-size(length), rest::binary>>) do
    [data | parse_raw(rest)]
  end

  defimpl DNS.Parameter, for: DNS.Message.Record.Data.TXT do
    @impl true
    def to_iodata(%DNS.Message.Record.Data.TXT{raw: raw, rdlength: rdlength}) do
      <<rdlength::16, raw::binary>>
    end
  end

  defimpl String.Chars, for: DNS.Message.Record.Data.TXT do
    def to_string(%DNS.Message.Record.Data.TXT{data: data}) do
      "#{data |> Enum.map(&inspect/1) |> Enum.join(" ")}"
    end
  end
end
