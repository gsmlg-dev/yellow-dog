defmodule DNS.Message.Record.Data.Behaviour do
  @moduledoc """
  Behaviour for DNS record data implementations.

  This module defines the interface that all DNS record data implementations must follow.
  Implementations should implement the DNS.Parameter and String.Chars protocols as well.
  """

  @type t :: struct()
  @type raw_data :: term()

  @doc """
  Return the DNS record type code for this implementation.
  """
  @callback record_type() :: non_neg_integer()

  @doc """
  Create a new record data instance from the given raw data.
  The raw data format varies by record type.
  """
  @callback new(raw_data()) :: t()

  @doc """
  Parse record data from binary format.
  """
  @callback from_iodata(binary(), binary() | nil) :: t()

  @doc """
  Get the length of the record data in binary format.
  """
  @callback rdlength(t()) :: non_neg_integer()

  @doc """
  Validate the record data structure and content.
  """
  @callback validate(t()) :: :ok | {:error, term()}

  @optional_callbacks validate: 1
end
