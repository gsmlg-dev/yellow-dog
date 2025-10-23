defprotocol DNS.Parameter do
  @moduledoc """
  Protocol for converting DNS entities to binary protocol data.

  This protocol provides a standardized way to convert DNS entities (messages,
  records, domains, etc.) to their binary representation for network transmission
  according to DNS protocol specifications.

  All DNS resource types implement this protocol to ensure consistent
  binary serialization across the library.
  """

  @doc """
  Convert a DNS entity to binary iodata suitable for network transmission.

  ## Parameters

  * `value` - The DNS entity to convert (domain, record, message, etc.)

  ## Returns

  * `iodata()` - Binary data representing the DNS entity in protocol format

  ## Examples

      iex> domain = DNS.Message.Domain.new("example.com")
      iex> DNS.Parameter.to_iodata(domain)
      <<13, 101, 120, 97, 109, 112, 108, 101, 46, 99, 111, 109, 0>>
  """
  @spec to_iodata(term()) :: iodata()
  def to_iodata(value)
end

defimpl DNS.Parameter, for: List do
  @moduledoc """
  Implementation of DNS.Parameter for lists.

  Converts a list of DNS entities by recursively converting each element
  and concatenating the results.
  """

  @impl true
  @doc """
  Convert a list of DNS entities to binary iodata.

  Each element in the list is converted using DNS.Parameter.to_iodata/1
  and the results are concatenated.
  """
  @spec to_iodata(list(term())) :: iodata()
  def to_iodata(list) do
    list |> Enum.map(&DNS.to_iodata/1) |> Enum.join(<<>>)
  end
end

defimpl DNS.Parameter, for: BitString do
  @moduledoc """
  Implementation of DNS.Parameter for binaries.

  Treats binary strings as domain names and converts them to the appropriate
  DNS domain format.
  """

  @impl true
  @doc """
  Convert a binary string to DNS domain format.

  The binary is treated as a domain name and converted using DNS.Message.Domain.
  """
  @spec to_iodata(binary()) :: iodata()
  def to_iodata(value) when is_binary(value) do
    DNS.Message.Domain.new(value) |> DNS.Parameter.to_iodata()
  end
end
