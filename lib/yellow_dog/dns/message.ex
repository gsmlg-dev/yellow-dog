defmodule YellowDog.DNS.Message do
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

  alias YellowDog.DNS.Message
  alias YellowDog.DNS.Message.Header
  alias YellowDog.DNS.Message.Question
  alias YellowDog.DNS.Message.Record

  @type t :: %__MODULE__{
          header: %Header{},
          # Question list
          qdlist: list(%Question{}),
          # Answer list
          anlist: list(%Record{}),
          # Authority list
          nslist: list(%Record{}),
          # Additional record list
          arlist: list(%Record{})
        }

  defstruct header: %Header{},
            qdlist: [],
            anlist: [],
            nslist: [],
            arlist: []

  def to_buffer(
        _message = %Message{
          header: header,
          qdlist: qdlist,
          anlist: anlist,
          nslist: nslist,
          arlist: arlist
        }
      ) do
    <<
      Header.to_buffer(header)::binary,
      Question.to_buffer(qdlist)::binary,
      Record.list_to_buffer(anlist)::binary,
      Record.list_to_buffer(nslist)::binary,
      Record.list_to_buffer(arlist)::binary
    >>
  end

  def from_buffer(<<header::12, next>>) do
    %Message{
      header: Header.from_buffer(header)
    }
  end

  def new do
    %Message{
      header: Header.new(),
      qdlist: [],
      anlist: [],
      nslist: [],
      arlist: []
    }
  end

  def name_to_buffer(name) do
    case String.split(name, ".") |> Enum.filter(&(&1 != "")) do
      [] ->
        <<0>>

      list ->
        list
        |> Enum.reverse()
        |> Enum.reduce(<<0>>, fn part, acc ->
          part_length = byte_size(part)
          <<part_length::8, part::binary-size(part_length), acc::binary>>
        end)
    end
  end

  def name_from_buffer(buffer, message \\ <<>>)
  def name_from_buffer(<<0>>, _), do: "."

  def name_from_buffer(buffer, message)
      when is_bitstring(buffer) and byte_size(buffer) > 0 do
    case buffer do
      <<0, _>> ->
        "."

      <<0xC0, pos::8, _::binary>> ->
        case message do
          <<_::binary-size(pos), next::8, next_buffer::binary>> ->
            name_from_buffer(<<next::8, next_buffer::binary>>, message)

          _ ->
            throw(FormatError)
        end

      <<size::8, rest::binary>> when size < 64 and size > 0 ->
        case rest do
          <<part::binary-size(size), 0::8, _::binary>> ->
            part <> "."

          <<part::binary-size(size), next::8, next_buffer::binary>> ->
            part <> "." <> name_from_buffer(<<next, next_buffer::binary>>, message)

          <<_::binary-size(size), _::binary>> ->
            throw(FormatError)
        end

      _ ->
        throw(FormatError)
    end
  end
end
