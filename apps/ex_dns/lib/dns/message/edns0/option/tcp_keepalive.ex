defmodule DNS.Message.EDNS0.Option.TcpKeepalive do
  @moduledoc """
  EDNS0.Option.TcpKeepalive [RFC7828](https://datatracker.ietf.org/doc/html/rfc7828)

  The edns-tcp-keepalive option is used to negotiate TCP keepalive
  parameters between DNS clients and servers.

  Option Format:

                        1 1 1 1 1 1 1 1 1 1 2 2 2 2 2 2 2 2 2 2 3 3
    0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    |        OPTION-CODE = 11       |       OPTION-LENGTH           |
    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    |                      TIMEOUT-COUNT                            |
    |                                                               |
    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+

  - TIMEOUT-COUNT: 2 octets, timeout value in 100ms units (or 0 if not specified)
  """
  alias DNS.Message.EDNS0.OptionCode

  @type t :: %__MODULE__{
          code: OptionCode.t(),
          length: 0..65535,
          data: timeout_count :: 0..65535 | nil
        }

  defstruct code: OptionCode.new(11), length: nil, data: nil

  @spec new(integer() | nil) :: t()
  def new(timeout_count \\ nil) do
    case timeout_count do
      nil ->
        %__MODULE__{length: 0, data: nil}

      timeout when is_integer(timeout) ->
        %__MODULE__{length: 2, data: timeout}
    end
  end

  def from_iodata(<<11::16, 0::16>>) do
    %__MODULE__{length: 0, data: nil}
  end

  def from_iodata(<<11::16, 2::16, timeout_count::16>>) do
    %__MODULE__{length: 2, data: timeout_count}
  end

  defimpl DNS.Parameter, for: DNS.Message.EDNS0.Option.TcpKeepalive do
    @impl true
    def to_iodata(%DNS.Message.EDNS0.Option.TcpKeepalive{data: nil}) do
      <<11::16, 0::16>>
    end

    def to_iodata(%DNS.Message.EDNS0.Option.TcpKeepalive{data: timeout_count}) do
      <<11::16, 2::16, timeout_count::16>>
    end
  end

  defimpl String.Chars, for: DNS.Message.EDNS0.Option.TcpKeepalive do
    def to_string(%DNS.Message.EDNS0.Option.TcpKeepalive{code: code, data: nil}) do
      "#{code}: not specified"
    end

    def to_string(%DNS.Message.EDNS0.Option.TcpKeepalive{code: code, data: timeout_count}) do
      "#{code}: #{timeout_count * 100}ms"
    end
  end
end
