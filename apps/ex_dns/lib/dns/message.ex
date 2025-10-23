defmodule DNS.Message do
  @moduledoc """
  # DNS Message

  All communications inside of the domain protocol are carried in a single
  format called a message.  The top level format of message is divided
  into 5 sections (some of which are empty in certain cases) shown below:

      +---------------------+
      |        Header       |
      +---------------------+
      |       Question      | the question for the name server
      +---------------------+
      |        Answer       | RRs answering the question
      +---------------------+
      |      Authority      | RRs pointing toward an authority
      +---------------------+
      |      Additional     | RRs holding additional information
      +---------------------+

  The header section is always present.  The header includes fields that
  specify which of the remaining sections are present, and also specify
  whether the message is a query or a response, a standard query or some
  other opcode, etc.

  The names of the sections after the header are derived from their use in
  standard queries.  The question section contains fields that describe a
  question to a name server.  These fields are a query type (QTYPE), a
  query class (QCLASS), and a query domain name (QNAME).  The last three
  sections have the same format: a possibly empty list of concatenated
  resource records (RRs).  The answer section contains RRs that answer the
  question; the authority section contains RRs that point toward an
  authoritative name server; the additional records section contains RRs
  which relate to the query, but are not strictly answers for the
  question.

  """

  # alias DNS.Message
  alias DNS.Message.Header
  alias DNS.Message.Question
  alias DNS.Message.Record
  alias DNS.ResourceRecordType, as: RRType

  @type t :: %__MODULE__{
          header: %Header{},
          # Question list
          qdlist: list(%Question{}),
          # Answer list
          anlist: list(%Record{}),
          # Authority list
          nslist: list(%Record{}),
          # Additional record list
          arlist: list(%Record{}),
          options: Keyword.t()
        }

  defstruct header: %Header{},
            qdlist: [],
            anlist: [],
            nslist: [],
            arlist: [],
            options: []

  def new() do
    %__MODULE__{
      header: Header.new(),
      qdlist: [],
      anlist: [],
      nslist: [],
      arlist: [],
      options: []
    }
  end

  def from_iodata(<<header_bytes::binary-size(12), _::binary>> = message) do
    header = Header.from_iodata(header_bytes)

    {qdlist, qd_size} = Question.list_from_message(message, header.qdcount)

    {anlist, offset} = Record.list_from_message(header.ancount, message, 12 + qd_size)

    {nslist, offset} =
      Record.list_from_message(header.nscount, message, offset)

    {arlist, _} =
      Record.list_from_message(header.arcount, message, offset)

    %__MODULE__{
      header: header,
      qdlist: qdlist,
      anlist: anlist,
      nslist: nslist,
      arlist: arlist
    }
  end

  def update_header_attr(%__MODULE__{header: header} = message, key, value) do
    header = Map.put(header, key, value)
    %{message | header: header}
  end

  def add_question(%__MODULE__{qdlist: qdlist, header: header} = message, %Question{} = question) do
    %{message | qdlist: [question | qdlist], header: %{header | qdcount: header.qdcount + 1}}
  end

  def put_option(%__MODULE__{options: options} = message, key, value) do
    options = Keyword.put(options, key, value)
    %{message | options: options}
  end

  def get_option(%__MODULE__{options: options} = _message, key, default_value \\ nil) do
    Keyword.get(options, key, default_value)
  end

  defimpl DNS.Parameter, for: DNS.Message do
    @impl true
    def to_iodata(%DNS.Message{header: header, qdlist: qdlist, anlist: anlist, arlist: arlist}) do
      <<DNS.to_iodata(header)::binary, DNS.to_iodata(qdlist)::binary,
        DNS.to_iodata(anlist)::binary, DNS.to_iodata(arlist)::binary>>
    end
  end

  defimpl String.Chars, for: DNS.Message do
    def to_string(message) do
      anlist_str =
        if length(message.anlist) > 0 do
          "\n\n;; ANSWER SECTION\n#{message.anlist |> Enum.map(&Kernel.to_string/1) |> Enum.join("\n")}"
        else
          ""
        end

      nslist_str =
        if length(message.nslist) > 0 do
          "\n\n;; AUTHORITY SECTION\n#{message.nslist |> Enum.map(&Kernel.to_string/1) |> Enum.join("\n")}"
        else
          ""
        end

      otp = message.arlist |> Enum.find(fn record -> record.type == RRType.new(41) end)
      arlist = message.arlist |> Enum.filter(fn record -> record.type != RRType.new(41) end)

      edns0 =
        if !is_nil(otp) do
          otp
          |> DNS.to_iodata()
          |> DNS.Message.EDNS0.from_iodata()
        end

      arlist_str =
        if length(arlist) > 0 do
          "\n\n;; ADDITIONAL SECTION\n#{arlist |> Enum.map(&Kernel.to_string/1) |> Enum.join("\n")}"
        else
          ""
        end

      """
      ;; HEADER SECTION
      #{message.header}
      ;; QUESTION SECTION
      #{message.qdlist |> Enum.join("\n")}#{if(!is_nil(edns0), do: "\n#{edns0}", else: "")}#{anlist_str}#{nslist_str}#{arlist_str}
      """
    end
  end
end
