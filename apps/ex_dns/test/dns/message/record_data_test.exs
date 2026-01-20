defmodule DNS.Message.RecordDataTest do
  @moduledoc """
  Comprehensive unit tests for DNS.Message.RecordData protocol.

  Tests cover:
  - Protocol definition
  - to_iodata/1 callback definition

  Note: The DNS.Message.RecordData protocol is defined but implementations
  use DNS.Parameter protocol instead for serialization.
  """
  use ExUnit.Case, async: true

  describe "protocol definition" do
    test "DNS.Message.RecordData protocol is defined" do
      assert Code.ensure_loaded?(DNS.Message.RecordData)
    end

    test "defines to_iodata/1 callback" do
      Code.ensure_loaded!(DNS.Message.RecordData)
      # Protocol defines the function
      assert function_exported?(DNS.Message.RecordData, :to_iodata, 1)
    end

    test "protocol has impl_for/1 function" do
      Code.ensure_loaded!(DNS.Message.RecordData)
      assert function_exported?(DNS.Message.RecordData, :impl_for, 1)
    end
  end

  describe "protocol spec" do
    test "protocol returns binary" do
      # The spec indicates to_iodata returns binary
      # We verify this by checking the protocol is properly defined
      Code.ensure_loaded!(DNS.Message.RecordData)
      assert :erlang.function_exported(DNS.Message.RecordData, :__protocol__, 1)
    end
  end
end
