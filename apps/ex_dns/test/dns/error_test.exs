defmodule DNS.ErrorTest do
  use ExUnit.Case

  alias DNS.Error

  describe "new/4" do
    test "creates format error for Domain module" do
      error = Error.new(:format_error, DNS.Message.Domain, :test_reason)

      assert error == {"DNS.Message.Domain Format Error", %{internal_reason: :test_reason}}
    end

    test "creates security error for Record module" do
      context = %{rdlength: 8193}
      error = Error.new(:security_error, DNS.Message.Record, :rdlength_too_large, context)

      assert {"DNS.Message.Record Security Error",
              %{internal_reason: :rdlength_too_large, rdlength: 8193}} = error
    end

    test "creates compression error for Domain module" do
      context = %{depth: 6, max_depth: 5}
      error = Error.new(:compression_error, DNS.Message.Domain, :depth_exceeded, context)

      assert {"DNS.Message.Domain Compression Error",
              %{internal_reason: :depth_exceeded, depth: 6, max_depth: 5}} = error
    end

    test "handles unknown module gracefully" do
      error = Error.new(:format_error, Unknown.Module, :test_reason)

      # Update test to match actual implementation
      assert {"DNS Message Format Error", %{internal_reason: :test_reason}} = error
    end

    test "handles unknown error type gracefully" do
      error = Error.new(:unknown_error, DNS.Message.Domain, :test_reason)

      assert {"DNS Error", %{internal_reason: :test_reason}} = error
    end
  end

  describe "log_detailed_error/4" do
    test "logs detailed error when configured" do
      # Enable detailed error logging
      Application.put_env(:dns, :detailed_errors, true)

      # This should not raise an exception
      assert :ok =
               Error.log_detailed_error(:format_error, DNS.Message.Domain, :test_reason, %{
                 context: "test"
               })
    end

    test "does not log detailed errors when disabled" do
      # Disable detailed error logging
      Application.put_env(:dns, :detailed_errors, false)

      # This should not raise an exception
      assert :ok = Error.log_detailed_error(:format_error, DNS.Message.Domain, :test_reason)
    end

    test "handles complex error contexts" do
      context = %{
        buffer_size: 1024,
        position: 512,
        depth: 3,
        visited_positions: [0, 256, 512]
      }

      assert :ok =
               Error.log_detailed_error(
                 :compression_error,
                 DNS.Message.Domain,
                 :loop_detected,
                 context
               )
    end
  end

  describe "error message formatting" do
    test "provides consistent error messages" do
      domain_error = Error.new(:format_error, DNS.Message.Domain, :test)
      record_error = Error.new(:format_error, DNS.Message.Record, :test)
      question_error = Error.new(:format_error, DNS.Message.Question, :test)

      assert {"DNS.Message.Domain Format Error", _} = domain_error
      assert {"DNS.Message.Record Format Error", _} = record_error
      assert {"DNS.Message.Question Format Error", _} = question_error
    end

    test "handles all supported error types" do
      error_types = [
        {:format_error, DNS.Message.Domain},
        {:parse_error, DNS.Zone.FileParser},
        {:validation_error, DNS.Message.Record},
        {:compression_error, DNS.Message.Domain},
        {:security_error, DNS.Message.Record}
      ]

      Enum.each(error_types, fn {type, module} ->
        error = Error.new(type, module, :test)
        assert {error_message, error_map} = error
        assert is_binary(error_message)
        assert is_map(error_map)
        assert String.contains?(elem(error, 0), "DNS")
      end)
    end
  end

  describe "error context handling" do
    test "preserves context information" do
      context = %{rdlength: 1000, max_rdlength: 8192}
      error = Error.new(:security_error, DNS.Message.Record, :oversized_record, context)

      {"DNS.Message.Record Security Error", error_context} = error
      assert error_context.internal_reason == :oversized_record
      assert error_context.rdlength == 1000
      assert error_context.max_rdlength == 8192
    end

    test "merges context with internal reason" do
      context = %{existing_field: "existing"}
      error = Error.new(:format_error, DNS.Message.Domain, :new_reason, context)

      {"DNS.Message.Domain Format Error", error_context} = error
      assert error_context.internal_reason == :new_reason
      assert error_context.existing_field == "existing"
    end

    test "handles empty context" do
      error = Error.new(:format_error, DNS.Message.Domain, :test_reason)

      {"DNS.Message.Domain Format Error", error_context} = error
      assert error_context.internal_reason == :test_reason
      assert error_context == %{internal_reason: :test_reason}
    end
  end
end
