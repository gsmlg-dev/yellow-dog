defmodule DNS.Message.EDNS0.Option do
  @moduledoc """
  DNS EDNS0
  """

  alias DNS.Message.EDNS0.Option
  alias DNS.Message.EDNS0.OptionCode

  @type t :: %__MODULE__{
          code: OptionCode.t(),
          length: 0..65535,
          data: term()
        }

  defstruct code: nil, length: nil, data: nil

  def new(code, data) do
    case code do
      1 -> Option.LLQ.new(data)
      2 -> Option.UpdateLease.new(data)
      3 -> Option.NSID.new(data)
      5 -> Option.DAU.new(data)
      6 -> Option.DHU.new(data)
      7 -> Option.N3U.new(data)
      8 -> Option.ECS.new(data)
      9 -> Option.Expire.new(data)
      10 -> Option.Cookie.new(data)
      11 -> Option.TcpKeepalive.new(data)
      12 -> Option.Padding.new(data)
      13 -> Option.Chain.new(data)
      14 -> Option.KeyTag.new(data)
      15 -> Option.ExtendedDNSError.new(data)
      _ -> %__MODULE__{code: OptionCode.new(code), data: data}
    end
  end

  def from_iodata(<<code::16, length::16, payload::binary-size(length)>> = raw) do
    case code do
      1 -> Option.LLQ.from_iodata(raw)
      2 -> Option.UpdateLease.from_iodata(raw)
      3 -> Option.NSID.from_iodata(raw)
      5 -> Option.DAU.from_iodata(raw)
      6 -> Option.DHU.from_iodata(raw)
      7 -> Option.N3U.from_iodata(raw)
      8 -> Option.ECS.from_iodata(raw)
      9 -> Option.Expire.from_iodata(raw)
      10 -> Option.Cookie.from_iodata(raw)
      11 -> Option.TcpKeepalive.from_iodata(raw)
      12 -> Option.Padding.from_iodata(raw)
      13 -> Option.Chain.from_iodata(raw)
      14 -> Option.KeyTag.from_iodata(raw)
      15 -> Option.ExtendedDNSError.from_iodata(raw)
      _ -> %__MODULE__{code: OptionCode.new(code), data: payload}
    end
  end

  defimpl DNS.Parameter, for: DNS.Message.EDNS0.Option do
    @impl true
    def to_iodata(%DNS.Message.EDNS0.Option{
          data: data
        }) do
      <<10::16, byte_size(data)::16, data::binary>>
    end
  end

  defimpl String.Chars, for: DNS.Message.EDNS0.Option do
    def to_string(%DNS.Message.EDNS0.Option{
          code: code,
          data: data
        }) do
      "#{code}: #{Base.encode16(data)}"
    end
  end
end
