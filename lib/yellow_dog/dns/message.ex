def YellowDog.DNS.Message do
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

  @type t :: %__MODULE__{
    id: integer(), # ID: 16bit if 0 generate RandomID
    qr: 0 | 1, # QR: 1bit  query (0), or a response (1)
    opcode: integer(), # OPCode: 4bit YellowDog.DNS.OpCode.t(),
    aa: 0 | 1, # AA: 1bit Authoritative Answer
    tc: 0 | 1, # TC: 1bit TrunCation
    rd: 0 | 1, # RD: 1bit Recursion Desired
    ra: 0 | 1, # RA: 1bit Recursion Available
    z: 0 | 1, # Z: 1bit Reserved for future use
    ad: 0 | 1, # AD: 1bit Authenticated Data
    cd: 0 | 1, # CD: 1bit Checking Disabled
    rcode: integer(), # RCode: 4bit YellowDog.DNS.RCode.t(),
    qdcount: integer(), # QDCOUNT: 16bit an unsigned integer specifying the number of entries in the question section.
    ancount: integer(), # ANCOUNT: 16bit an unsigned integer specifying the number of resource records in the answer section.
    nscount: integer(), # NSCOUNT: 16bit an unsigned integer specifying the number of name server resource records in the authority records section.
    arcount: integer() # ARCOUNT: 16bit an unsigned integer specifying the number of resource records in the additional records section.
  }

  defstruct header: %YellowDog.DNS.Header{},
    qdlist: [],
    anlist: [],
    nslist: [],
    arlist: []

  def to_buffer(message = %YellowDog.DNS.Message{header: header, qdlist: qdlist, anlist: anlist, nslist: nslist, arlist: arlist}) do
    <<
      YellowDog.DNS.Header.to_buffer(header)::binary(),
      YellowDog.DNS.Question.to_buffer(qdlist)::binary()>>

  end
end
