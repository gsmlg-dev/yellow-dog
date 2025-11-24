defmodule DNS.Message.Record.Data.SRV do
  alias DNS.Message.Domain

  @type t :: %__MODULE__{
          type: DNS.ResourceRecordType.t(),
          rdlength: 1..65535,
          raw: bitstring(),
          data: {0..65535, DNS.Message.Domain.t()}
        }

  defstruct raw: nil, type: DNS.ResourceRecordType.new(33), rdlength: nil, data: nil

  def new({priority, weight, port, str}) do
    domain = Domain.new(str)

    %__MODULE__{
      raw: <<priority::16, weight::16, port::16, DNS.to_iodata(domain)::binary>>,
      data: {priority, weight, port, domain},
      rdlength: domain.size + 6
    }
  end

  def from_iodata(<<priority::16, weight::16, port::16, data::binary>>, message \\ nil) do
    domain = Domain.from_iodata(data, message)

    %__MODULE__{
      raw: <<priority::16, weight::16, port::16, DNS.to_iodata(domain)::binary>>,
      data: {priority, weight, port, domain},
      rdlength: byte_size(data) + 6
    }
  end

  defimpl DNS.Parameter, for: DNS.Message.Record.Data.SRV do
    @impl true
    def to_iodata(%DNS.Message.Record.Data.SRV{raw: raw}) do
      <<byte_size(raw)::16, raw::binary>>
    end
  end

  defimpl String.Chars, for: DNS.Message.Record.Data.SRV do
    def to_string(%DNS.Message.Record.Data.SRV{data: {priority, weight, port, domain}}) do
      "#{priority} #{weight} #{port} #{domain}"
    end
  end
end
