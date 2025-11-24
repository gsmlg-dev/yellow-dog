defmodule DNS.Message.Record.Data.CNAME do
  alias DNS.Message.Domain

  @type t :: %__MODULE__{
          type: DNS.ResourceRecordType.t(),
          rdlength: 1..65535,
          raw: bitstring(),
          data: DNS.Message.Domain.t()
        }

  defstruct raw: nil, type: DNS.ResourceRecordType.new(5), rdlength: nil, data: nil

  def new(str) do
    domain = Domain.new(str)
    raw = DNS.to_iodata(domain)
    %__MODULE__{raw: raw, data: domain, rdlength: domain.size}
  end

  def from_iodata(raw, message \\ nil) do
    data = Domain.from_iodata(raw, message)
    %__MODULE__{raw: raw, data: data, rdlength: data.size}
  end

  defimpl DNS.Parameter, for: DNS.Message.Record.Data.CNAME do
    @impl true
    def to_iodata(%DNS.Message.Record.Data.CNAME{data: data}) do
      data = DNS.to_iodata(data)
      <<byte_size(data)::16, data::binary>>
    end
  end

  defimpl String.Chars, for: DNS.Message.Record.Data.CNAME do
    def to_string(%DNS.Message.Record.Data.CNAME{data: data}) do
      "#{data}"
    end
  end
end
