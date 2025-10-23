defmodule DNS.Message.Record.Data.AAAA do
  @type t :: %__MODULE__{
          type: DNS.ResourceRecordType.t(),
          rdlength: 16,
          raw: bitstring(),
          data: :inet.ip6_address()
        }

  defstruct raw: nil, type: DNS.ResourceRecordType.new(28), rdlength: 16, data: nil

  def new({a, b, c, d, e, f, g, h} = ip) do
    raw = <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>>
    %__MODULE__{raw: raw, data: ip}
  end

  def from_iodata(raw, _message \\ nil) do
    <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>> = raw
    %__MODULE__{raw: raw, data: {a, b, c, d, e, f, g, h}}
  end

  defimpl DNS.Parameter, for: DNS.Message.Record.Data.AAAA do
    @impl true
    def to_iodata(%DNS.Message.Record.Data.AAAA{} = data) do
      {a, b, c, d, e, f, g, h} = data.data
      <<16::16, a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>>
    end
  end

  defimpl String.Chars, for: DNS.Message.Record.Data.AAAA do
    def to_string(record) do
      case record.data |> :inet.ntoa() do
        ip when is_list(ip) -> "#{ip}"
        _ -> record.raw |> inspect()
      end
    end
  end
end
