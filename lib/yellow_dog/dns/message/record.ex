defmodule YellowDog.DNS.Message.Record do
  @moduledoc """
    Record is a struct that represents a DNS record.

    It contains
  """
  alias YellowDog.DNS.Message.Record

  @type t :: %__MODULE__{
          name: String.t()
        }

  defstruct name: ".",
            class: 0,
            ttl: 0,
            type: 0,
            data: nil

  def list_to_buffer(list) when is_list(list) do
    list |> Enum.map(&Record.to_buffer/1) |> IO.iodata_to_binary()
  end

  @doc """
    Converts a Record struct to binary data.
  """
  def to_buffer(record = %__MODULE__{}) do
    # TODO: Implement this function
  end
end
