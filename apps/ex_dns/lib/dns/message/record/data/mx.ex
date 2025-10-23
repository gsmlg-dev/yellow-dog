defmodule DNS.Message.Record.Data.MX do
  alias DNS.Message.Domain

  @type t :: %__MODULE__{
          type: DNS.ResourceRecordType.t(),
          rdlength: 1..65535,
          raw: bitstring(),
          data: {0..65535, DNS.Message.Domain.t()}
        }

  defstruct raw: nil, type: DNS.ResourceRecordType.new(15), rdlength: nil, data: nil

  def new({weight, str}) do
    domain = Domain.new(str)
    raw = DNS.to_iodata(domain)

    %__MODULE__{
      raw: <<weight::16, raw::binary>>,
      data: {weight, domain},
      rdlength: domain.size + 2
    }
  end

  def from_iodata(<<weight::16, data::binary>>, message \\ nil) do
    domain = Domain.from_iodata(data, message)

    %__MODULE__{
      raw: <<weight::16, DNS.to_iodata(domain)::binary>>,
      data: {weight, domain},
      rdlength: byte_size(data) + 2
    }
  end

  defimpl DNS.Parameter, for: DNS.Message.Record.Data.MX do
    @impl true
    def to_iodata(%DNS.Message.Record.Data.MX{data: {weight, domain}}) do
      data = DNS.to_iodata(domain)
      <<byte_size(data) + 2::16, weight::16, data::binary>>
    end
  end

  defimpl String.Chars, for: DNS.Message.Record.Data.MX do
    def to_string(%DNS.Message.Record.Data.MX{data: {weight, domain}}) do
      "#{weight} #{domain}"
    end
  end
end
