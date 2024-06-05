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

  # alias YellowDog.DNS.Message
  alias YellowDog.DNS.Message.Header
  alias YellowDog.DNS.Message.Question
  alias YellowDog.DNS.Message.Record
  alias YellowDog.DNS.ResourceRecord.Type, as: RType
  alias YellowDog.DNS.Message.EDNS0

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
        _message = %__MODULE__{
          header: header,
          qdlist: qdlist,
          anlist: anlist,
          nslist: nslist,
          arlist: arlist
        }
      ) do
    <<
      Header.to_buffer(header)::binary,
      Question.list_to_buffer(qdlist)::binary,
      Record.list_to_buffer(anlist)::binary,
      Record.list_to_buffer(nslist)::binary,
      Record.list_to_buffer(arlist)::binary
    >>
  end

  def from_buffer(<<header_bytes::binary-size(12), _::binary>> = message) do
    header = Header.from_buffer(header_bytes)
    {qd_size, qdlist} = Question.list_from_message(message, header.qdcount)
    {an_size, anlist} = Record.list_from_message(header.ancount, message, 12 + qd_size)

    {ns_size, nslist} =
      Record.list_from_message(header.nscount, message, 12 + qd_size + an_size)

    {_, arlist} =
      Record.list_from_message(header.arcount, message, 12 + qd_size + an_size + ns_size)

    %__MODULE__{
      header: header,
      qdlist: qdlist,
      anlist: anlist,
      nslist: nslist,
      arlist: arlist
    }
  end

  def new do
    %__MODULE__{
      header: Header.new(),
      qdlist: [],
      anlist: [],
      nslist: [],
      arlist: []
    }
  end

  def update_header_attr(message = %__MODULE__{}, name, value) do
    %__MODULE__{message | header: Map.put(message.header, name, value)}
  end

  def update_header(message = %__MODULE__{}, header = %Header{}) do
    %__MODULE__{message | header: Map.merge(message.header, header)}
  end

  def add_question(message = %__MODULE__{}, question = %Question{}) do
    %__MODULE__{
      message
      | qdlist: message.qdlist ++ [question],
        header: Map.put(message.header, :qdcount, message.header.qdcount + 1)
    }
  end

  def add_answer(message = %__MODULE__{}, record = %Record{}) do
    %__MODULE__{message | anlist: message.anlist ++ [record]}
  end

  def add_authority(message = %__MODULE__{}, record = %Record{}) do
    %__MODULE__{message | nslist: message.nslist ++ [record]}
  end

  def add_additional(message = %__MODULE__{}, record = %Record{}) do
    %__MODULE__{message | arlist: message.arlist ++ [record]}
  end

  def edns0?(message = %__MODULE__{}) do
    with true <- length(message.arlist) > 0,
         true <-
           Enum.find_index(message.arlist, fn n -> n.type == RType.opt() end) |> is_integer() do
      true
    else
      _ -> false
    end
  end

  def edns0(message = %__MODULE__{}) do
    Enum.find(message.arlist, fn n -> n.type == RType.opt() end)
    |> Record.to_buffer()
    |> EDNS0.from_buffer()
  end

  def set_edns0(message = %__MODULE__{}, edns0 = %EDNS0{}) do
    arlist =
      message.arlist
      |> Enum.filter(fn r -> r.type != RType.opt() end)

    r = edns0 |> EDNS0.to_buffer() |> Record.from_buffer() |> elem(1)

    %__MODULE__{message | arlist: [r | arlist]}
  end

  def to_print(message = %__MODULE__{}) do
    anlist_str =
      if length(message.anlist) > 0 do
        "\n;; ANSWER SECTION\n#{message.anlist |> Enum.map(&Record.to_print(&1)) |> Enum.join("\n")}"
      else
        ""
      end

    nslist_str =
      if length(message.nslist) > 0 do
        "\n;; AUTHORITY SECTION\n#{message.nslist |> Enum.map(&Record.to_print(&1)) |> Enum.join("\n")}"
      else
        ""
      end

    arlist =
      message.arlist
      |> Enum.filter(fn
        %Record{type: 41} ->
          false

        %Record{} ->
          true
      end)

    arlist_str =
      if length(arlist) > 0 do
        "\n;; ADDITIONAL SECTION\n#{arlist |> Enum.map(&Record.to_print(&1)) |> Enum.join("\n")}"
      else
        ""
      end

    """
    ;; HEADER SECTION
    #{message.header |> Header.to_print()}
    #{if(edns0?(message), do: ";; OPT PSEUDOSECTION\n#{message |> edns0() |> EDNS0.to_print()}")}
    ;; QUESTION SECTION
    #{message.qdlist |> Enum.map(&Question.to_print(&1)) |> Enum.join("\n")}
    #{anlist_str}#{nslist_str}#{arlist_str}
    """
  end

  @spec name_to_buffer(binary()) :: any()
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
  def name_from_buffer(<<size::8, _::binary>>, _) when size == 0, do: {1, "."}

  def name_from_buffer(<<size::8, pos::8, _::binary>>, message) when size == 0xC0 do
    case message do
      <<_::binary-size(pos), next::8, next_buffer::binary>> when next > 0 and next < 64 ->
        {_, name} = name_from_buffer(<<next::8, next_buffer::binary>>, message)
        {2, name}

      <<_::binary-size(pos), next::8, next_pos::8, next_buffer::binary>>
      when next == 0xC0 and pos != next_pos ->
        {_, name} = name_from_buffer(<<next::8, next_pos::8, next_buffer::binary>>, message)
        {2, name}

      _ ->
        throw(FormatError)
    end
  end

  def name_from_buffer(<<size::8, rest::binary>>, message)
      when size > 0 and size < 64 do
    case rest do
      <<part::binary-size(size), next::8, _::binary>> when next == 0 ->
        {1 + size + 1, part <> "."}

      <<part::binary-size(size), next::8, next_pos::8, last_buffer::binary>> when next == 0xC0 ->
        {_, compressed_name} =
          name_from_buffer(<<next::8, next_pos::8, last_buffer::binary>>, message)

        {1 + size + 2, part <> "." <> compressed_name}

      <<part::binary-size(size), next::8, next_buffer::binary>> when next > 0 and next < 64 ->
        {last_size, last_name} = name_from_buffer(<<next, next_buffer::binary>>, message)
        {1 + size + last_size, part <> "." <> last_name}

      <<_::binary-size(size), _::binary>> ->
        throw(FormatError)
    end
  end

  def name_from_buffer(buffer, message) do
    throw({:invalid_format, buffer, message})
  end
end
