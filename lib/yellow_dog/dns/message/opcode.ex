defmodule YellowDog.DNS.Message.OpCode do
  @moduledoc """
  # DNS OpCode

      OpCode 	Name 	Reference
      0	Query	[RFC1035]
      1	IQuery (Inverse Query, OBSOLETE)	[RFC3425]
      2	Status	[RFC1035]
      3	Unassigned
      4	Notify	[RFC1996]
      5	Update	[RFC2136]
      6	DNS Stateful Operations (DSO)	[RFC8490]
      7-15	Unassigned

  # Reference
  - [iana](https://www.iana.org/assignments/dns-parameters/dns-parameters.xhtml#dns-parameters-5)
  - [DOMAIN NAMES - IMPLEMENTATION AND SPECIFICATION](https://tools.ietf.org/html/rfc1035)
  - [Domain Name System (DNS) IANA Considerations](https://tools.ietf.org/html/rfc6895)
  """

  @doc """
  # query is a standard query
  [RFC1035](https://tools.ietf.org/html/rfc1035)
  """
  @spec query() :: 0
  def query(), do: 0

  @doc """
  # iquery is a non-standard extension to DNS that is used by the
  [DNS Zone Transfer Protocol](https://tools.ietf.org/html/rfc1996)
  """
  @spec iquery() :: 1
  def iquery(), do: 1

  @doc """
  # status is a non-standard extension to DNS that is used by the
  [DNS Zone Transfer Protocol](https://tools.ietf.org/html/rfc1996)
  """
  @spec status() :: 2
  def status(), do: 2

  @doc """
  # notify is a non-standard extension to DNS that is used by the
  [DNS Zone Transfer Protocol](https://tools.ietf.org/html/rfc1996)
  """
  @spec notify() :: 4
  def notify(), do: 4

  @doc """
  # update is a non-standard extension to DNS that is used by the
  [Dynamic DNS Update](https://tools.ietf.org/html/rfc2136)
  """
  @spec update() :: 5
  def update(), do: 5

  @doc """
  # dso is a non-standard extension to DNS that is used by the
  [DNS Stateful Operations (DSO)](https://tools.ietf.org/html/draft-sekar-dns-ultradns-00)
  """
  @spec dso() :: 6
  def dso(), do: 6

  @spec get_name(0 | 1 | 2 | 4 | 5 | 6) :: :dso | :iquery | :notify | :query | :status | :update
  def get_name(0), do: :query
  def get_name(1), do: :iquery
  def get_name(2), do: :status
  def get_name(4), do: :notify
  def get_name(5), do: :update
  def get_name(6), do: :dso

  def get_name(code) when is_integer(code) and (code == 3 or (code > 6 and code <= 15)) do
    :unassigned
  end
end
