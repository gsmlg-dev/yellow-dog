defmodule DHCPv4.Message.Option.Helpers do
  @moduledoc """
  Helper functions for DHCPv4 option processing.

  This module provides common utility functions used throughout
  the DHCPv4 option handling modules.
  """

  alias DHCPv4.Message.Option

  @magic_cookie <<99, 130, 83, 99>>
  @end_option 0xFF

  @doc """
  Get the magic cookie value.
  """
  def magic_cookie, do: @magic_cookie

  @doc """
  Get the end option value.
  """
  def end_option, do: @end_option

  @doc """
  Create a new option struct.
  """
  def new(type, length, value) do
    %Option{
      type: type,
      length: length,
      value: value
    }
  end

  @doc """
  Parse option from iodata format.
  """
  def from_iodata(<<type::8, length::8, value::binary-size(length)>>) do
    new(type, length, value)
  end

  @doc """
  Convert option to iodata format.
  """
  def to_iodata(%Option{type: type, length: length, value: value}) do
    <<type::8, length::8, value::binary-size(length)>>
  end
end
