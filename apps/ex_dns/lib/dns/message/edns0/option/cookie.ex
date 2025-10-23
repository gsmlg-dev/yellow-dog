defmodule DNS.Message.EDNS0.Option.Cookie do
  @moduledoc """
  EDNS0.Option.Cookie

  The DNS COOKIE option is an OPT RR [RFC6891] option that can be
  included in the RDATA portion of an OPT RR in DNS requests and
  responses.  The option length varies, depending on the circumstances
  in which it is being used.  There are two cases, as described below.
  Both use the same OPTION-CODE; they are distinguished by their
  length.

  In a request sent by a client to a server when the client does not
  know the server's cookie, its length is 8, consisting of an 8-byte
  Client Cookie, as shown in Figure 1.

                            1 1 1 1 1 1 1 1 1 1 2 2 2 2 2 2 2 2 2 2 3 3
        0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
        +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
        |        OPTION-CODE = 10      |       OPTION-LENGTH = 8        |
        +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
        |                                                               |
        +-+-    Client Cookie (fixed size, 8 bytes)              -+-+-+-+
        |                                                               |
        +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+

              Figure 1: COOKIE Option, Unknown Server Cookie

   In a request sent by a client when a Server Cookie is known, and in
   all responses to such a request, the length is variable -- from 16 to
   40 bytes, consisting of an 8-byte Client Cookie followed by the
   variable-length (8 bytes to 32 bytes) Server Cookie, as shown in
   Figure 2.  The variability of the option length stems from the
   variable-length Server Cookie.  The Server Cookie is an integer
   number of bytes, with a minimum size of 8 bytes for security and a
   maximum size of 32 bytes for convenience of implementation.

                            1 1 1 1 1 1 1 1 1 1 2 2 2 2 2 2 2 2 2 2 3 3
        0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
        +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
        |        OPTION-CODE = 10      |   OPTION-LENGTH >= 16, <= 40   |
        +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
        |                                                               |
        +-+-    Client Cookie (fixed size, 8 bytes)              -+-+-+-+
        |                                                               |
        +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
        |                                                               |
        /       Server Cookie  (variable size, 8 to 32 bytes)           /
        /                                                               /
        +-+-+-+-...

               Figure 2: COOKIE Option, Known Server Cookie
  """
  alias DNS.Message.EDNS0.OptionCode

  @type t :: %__MODULE__{
          code: OptionCode.t(),
          length: 8 | 16..40,
          data: {client_cookie :: binary(), server_cookie :: binary() | nil}
        }

  defstruct code: OptionCode.new(10), length: nil, data: nil

  @spec new({binary(), binary() | nil}) :: t()
  def new({client_cookie, server_cookie}) do
    len =
      if is_nil(server_cookie) do
        8
      else
        8 + byte_size(server_cookie)
      end

    %__MODULE__{length: len, data: {client_cookie, server_cookie}}
  end

  def from_iodata(<<10::16, 8::16, client_cookie::binary-size(8)>>) do
    %__MODULE__{length: 8, data: {client_cookie, nil}}
  end

  def from_iodata(
        <<10::16, len::16, client_cookie::binary-size(8), server_cookie::binary-size(len - 8)>>
      )
      when len >= 16 and len <= 40 do
    %__MODULE__{length: len, data: {client_cookie, server_cookie}}
  end

  defimpl DNS.Parameter, for: DNS.Message.EDNS0.Option.Cookie do
    @impl true
    def to_iodata(%DNS.Message.EDNS0.Option.Cookie{
          data: {client_cookie, nil}
        }) do
      <<10::16, 8::16, client_cookie::binary-size(8)>>
    end

    def to_iodata(%DNS.Message.EDNS0.Option.Cookie{
          data: {client_cookie, server_cookie}
        }) do
      s_size = byte_size(server_cookie)
      <<10::16, 8 + s_size::16, client_cookie::binary-size(8), server_cookie::binary>>
    end
  end

  defimpl String.Chars, for: DNS.Message.EDNS0.Option.Cookie do
    def to_string(%DNS.Message.EDNS0.Option.Cookie{
          code: code,
          data: {client_cookie, nil}
        }) do
      "#{code}: #{Base.encode16(client_cookie)}"
    end

    def to_string(%DNS.Message.EDNS0.Option.Cookie{
          code: code,
          data: {client_cookie, server_cookie}
        }) do
      "#{code}: #{Base.encode16(client_cookie)} #{Base.encode16(server_cookie)}"
    end
  end
end
