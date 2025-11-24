defmodule DNS.Zone.RRSet do
  @moduledoc """
  DNS Resource Record Set
  """

  alias DNS.Zone.Name
  alias DNS.ResourceRecordType, as: RRType

  @type t :: %__MODULE__{
          name: Name.t(),
          type: RRType.t(),
          ttl: 0..4_294_967_295,
          data: list(term()),
          options: list(term())
        }

  defstruct name: nil, type: nil, ttl: 0, data: [], options: []

  @spec new(any(), any(), any()) :: DNS.Zone.RRSet.t()
  def new(name, type, data \\ [], options \\ []) do
    {ttl, options} = Keyword.pop(options, :ttl, 0)

    %__MODULE__{
      name: name,
      type: type,
      data: data,
      ttl: ttl,
      options: options
    }
  end
end
