defmodule DNS.ErrorTest do
  @moduledoc """
  Comprehensive unit tests for DNS.Error module.

  Tests cover:
  - Module structure and exports
  - new/4 error creation with all error types
  - All supported module/error type combinations
  - Context preservation and merging
  - log_detailed_error/4 with telemetry
  - Error message formatting
  - Security considerations (information hiding)
  - Edge cases and boundary conditions
  """
  use ExUnit.Case, async: true

  alias DNS.Error

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(Error)
    end

    test "exports new/4" do
      Code.ensure_loaded!(Error)
      assert Kernel.function_exported?(Error, :new, 4)
    end

    test "exports new/3" do
      Code.ensure_loaded!(Error)
      # new/3 is the default arity with context defaulting to %{}
      assert Kernel.function_exported?(Error, :new, 3)
    end

    test "exports log_detailed_error/4" do
      Code.ensure_loaded!(Error)
      assert Kernel.function_exported?(Error, :log_detailed_error, 4)
    end

    test "exports log_detailed_error/3" do
      Code.ensure_loaded!(Error)
      # log_detailed_error/3 with context defaulting to %{}
      assert Kernel.function_exported?(Error, :log_detailed_error, 3)
    end

    test "defines error_type type" do
      # Verify type is defined by checking behavior
      {:ok, _} = Code.Typespec.fetch_types(Error)
    end
  end

  describe "new/4 basic creation" do
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

      # Falls back to generic message for unknown modules
      assert {"DNS Message Format Error", %{internal_reason: :test_reason}} = error
    end

    test "handles unknown error type gracefully" do
      error = Error.new(:unknown_error, DNS.Message.Domain, :test_reason)

      assert {"DNS Error", %{internal_reason: :test_reason}} = error
    end

    test "returns tuple with string and map" do
      error = Error.new(:format_error, DNS.Message.Domain, :test)
      assert {message, context} = error
      assert is_binary(message)
      assert is_map(context)
    end
  end

  describe "new/4 format_error type" do
    test "formats Domain module" do
      error = Error.new(:format_error, DNS.Message.Domain, :test)
      assert {"DNS.Message.Domain Format Error", _} = error
    end

    test "formats Record module" do
      error = Error.new(:format_error, DNS.Message.Record, :test)
      assert {"DNS.Message.Record Format Error", _} = error
    end

    test "formats Question module" do
      error = Error.new(:format_error, DNS.Message.Question, :test)
      assert {"DNS.Message.Question Format Error", _} = error
    end

    test "formats Header module" do
      error = Error.new(:format_error, DNS.Message.Header, :test)
      assert {"DNS.Message.Header Format Error", _} = error
    end

    test "falls back for unknown module" do
      error = Error.new(:format_error, SomeOther.Module, :test)
      assert {"DNS Message Format Error", _} = error
    end
  end

  describe "new/4 parse_error type" do
    test "formats Domain module" do
      error = Error.new(:parse_error, DNS.Message.Domain, :test)
      assert {"DNS.Message.Domain Parse Error", _} = error
    end

    test "formats Record module" do
      error = Error.new(:parse_error, DNS.Message.Record, :test)
      assert {"DNS.Message.Record Parse Error", _} = error
    end

    test "formats FileParser module" do
      error = Error.new(:parse_error, DNS.Zone.FileParser, :test)
      assert {"DNS Zone File Parse Error", _} = error
    end

    test "falls back for unknown module" do
      error = Error.new(:parse_error, SomeOther.Module, :test)
      assert {"DNS Parse Error", _} = error
    end
  end

  describe "new/4 validation_error type" do
    test "formats Record module" do
      error = Error.new(:validation_error, DNS.Message.Record, :test)
      assert {"DNS.Message.Record Validation Error", _} = error
    end

    test "formats FileParser module" do
      error = Error.new(:validation_error, DNS.Zone.FileParser, :test)
      assert {"DNS Zone File Validation Error", _} = error
    end

    test "falls back for unknown module" do
      error = Error.new(:validation_error, SomeOther.Module, :test)
      assert {"DNS Validation Error", _} = error
    end
  end

  describe "new/4 compression_error type" do
    test "formats Domain module" do
      error = Error.new(:compression_error, DNS.Message.Domain, :test)
      assert {"DNS.Message.Domain Compression Error", _} = error
    end

    test "falls back for other modules" do
      error = Error.new(:compression_error, DNS.Message.Record, :test)
      assert {"DNS Compression Error", _} = error
    end

    test "falls back for unknown module" do
      error = Error.new(:compression_error, SomeOther.Module, :test)
      assert {"DNS Compression Error", _} = error
    end
  end

  describe "new/4 security_error type" do
    test "formats Domain module" do
      error = Error.new(:security_error, DNS.Message.Domain, :test)
      assert {"DNS.Message.Domain Security Error", _} = error
    end

    test "formats Record module" do
      error = Error.new(:security_error, DNS.Message.Record, :test)
      assert {"DNS.Message.Record Security Error", _} = error
    end

    test "formats FileParser module" do
      error = Error.new(:security_error, DNS.Zone.FileParser, :test)
      assert {"DNS Zone File Security Error", _} = error
    end

    test "falls back for unknown module" do
      error = Error.new(:security_error, SomeOther.Module, :test)
      assert {"DNS Security Error", _} = error
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

    test "returns :ok regardless of configuration" do
      Application.put_env(:dns, :detailed_errors, true)
      assert :ok = Error.log_detailed_error(:format_error, DNS.Message.Domain, :test)

      Application.put_env(:dns, :detailed_errors, false)
      assert :ok = Error.log_detailed_error(:format_error, DNS.Message.Domain, :test)
    end

    test "handles all error types" do
      error_types = [:format_error, :parse_error, :validation_error, :compression_error, :security_error]

      for type <- error_types do
        assert :ok = Error.log_detailed_error(type, DNS.Message.Domain, :test)
      end
    end

    test "handles empty context" do
      assert :ok = Error.log_detailed_error(:format_error, DNS.Message.Domain, :test)
    end

    test "handles large context" do
      context = Map.new(1..100, fn i -> {"key_#{i}", "value_#{i}"} end)
      assert :ok = Error.log_detailed_error(:format_error, DNS.Message.Domain, :test, context)
    end

    test "handles nested context" do
      context = %{
        outer: %{
          inner: %{
            deep: "value"
          }
        }
      }
      assert :ok = Error.log_detailed_error(:format_error, DNS.Message.Domain, :test, context)
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

    test "error messages contain relevant keywords" do
      format_error = Error.new(:format_error, DNS.Message.Domain, :test)
      parse_error = Error.new(:parse_error, DNS.Message.Domain, :test)
      validation_error = Error.new(:validation_error, DNS.Message.Record, :test)
      compression_error = Error.new(:compression_error, DNS.Message.Domain, :test)
      security_error = Error.new(:security_error, DNS.Message.Record, :test)

      assert elem(format_error, 0) =~ "Format"
      assert elem(parse_error, 0) =~ "Parse"
      assert elem(validation_error, 0) =~ "Validation"
      assert elem(compression_error, 0) =~ "Compression"
      assert elem(security_error, 0) =~ "Security"
    end

    test "all messages start with DNS" do
      modules = [
        DNS.Message.Domain,
        DNS.Message.Record,
        DNS.Message.Question,
        DNS.Message.Header,
        DNS.Zone.FileParser,
        Unknown.Module
      ]

      types = [:format_error, :parse_error, :validation_error, :compression_error, :security_error]

      for type <- types, module <- modules do
        {message, _} = Error.new(type, module, :test)
        assert String.starts_with?(message, "DNS")
      end
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

    test "overwrites internal_reason if present in context" do
      context = %{internal_reason: :old_reason}
      error = Error.new(:format_error, DNS.Message.Domain, :new_reason, context)

      {_, error_context} = error
      assert error_context.internal_reason == :new_reason
    end

    test "preserves complex data types in context" do
      context = %{
        list: [1, 2, 3],
        tuple: {:a, :b},
        nested: %{key: "value"},
        binary: <<1, 2, 3>>
      }
      error = Error.new(:format_error, DNS.Message.Domain, :test, context)

      {_, error_context} = error
      assert error_context.list == [1, 2, 3]
      assert error_context.tuple == {:a, :b}
      assert error_context.nested == %{key: "value"}
      assert error_context.binary == <<1, 2, 3>>
    end
  end

  describe "security considerations" do
    test "error messages do not expose buffer contents" do
      # Simulating a malformed DNS packet
      buffer = <<0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01, 0x02, 0x03>>
      context = %{buffer: buffer, position: 4}

      error = Error.new(:format_error, DNS.Message.Domain, :malformed_packet, context)
      {message, _} = error

      # The message should not contain raw buffer bytes
      refute message =~ inspect(buffer)
      refute message =~ "0xDE"
      refute message =~ "\\xDE"
    end

    test "error messages are generic enough to prevent information disclosure" do
      # These are the kinds of internal details that should NOT be in the message
      internal_details = [
        :memory_address,
        :stack_trace,
        :internal_state,
        :buffer_position
      ]

      for detail <- internal_details do
        error = Error.new(:security_error, DNS.Message.Domain, detail)
        {message, _} = error

        # The message should not expose the specific internal detail
        refute message =~ to_string(detail)
      end
    end

    test "internal reason stored in context, not message" do
      error = Error.new(:security_error, DNS.Message.Record, :buffer_overflow_attempt)
      {message, context} = error

      # Reason in context for internal logging
      assert context.internal_reason == :buffer_overflow_attempt

      # But not exposed in the public message
      refute message =~ "buffer_overflow_attempt"
    end
  end

  describe "all module/type combinations" do
    @modules [
      DNS.Message.Domain,
      DNS.Message.Record,
      DNS.Message.Question,
      DNS.Message.Header,
      DNS.Zone.FileParser,
      Unknown.Module
    ]

    @error_types [:format_error, :parse_error, :validation_error, :compression_error, :security_error, :unknown_type]

    test "all combinations produce valid errors" do
      for module <- @modules, type <- @error_types do
        error = Error.new(type, module, :test_reason)
        assert {message, context} = error
        assert is_binary(message)
        assert is_map(context)
        assert Map.has_key?(context, :internal_reason)
      end
    end
  end

  describe "reason types" do
    test "handles atom reasons" do
      error = Error.new(:format_error, DNS.Message.Domain, :invalid_label)
      {_, context} = error
      assert context.internal_reason == :invalid_label
    end

    test "handles string reasons" do
      error = Error.new(:format_error, DNS.Message.Domain, "invalid label")
      {_, context} = error
      assert context.internal_reason == "invalid label"
    end

    test "handles tuple reasons" do
      error = Error.new(:format_error, DNS.Message.Domain, {:invalid, :reason})
      {_, context} = error
      assert context.internal_reason == {:invalid, :reason}
    end

    test "handles map reasons" do
      reason = %{code: 1, message: "error"}
      error = Error.new(:format_error, DNS.Message.Domain, reason)
      {_, context} = error
      assert context.internal_reason == reason
    end

    test "handles integer reasons" do
      error = Error.new(:format_error, DNS.Message.Domain, 42)
      {_, context} = error
      assert context.internal_reason == 42
    end

    test "handles nil reason" do
      error = Error.new(:format_error, DNS.Message.Domain, nil)
      {_, context} = error
      assert context.internal_reason == nil
    end
  end

  describe "realistic error scenarios" do
    test "domain compression loop detected" do
      context = %{
        position: 256,
        visited: [0, 128, 256],
        max_depth: 5,
        current_depth: 6
      }
      error = Error.new(:compression_error, DNS.Message.Domain, :loop_detected, context)

      {message, ctx} = error
      assert message == "DNS.Message.Domain Compression Error"
      assert ctx.internal_reason == :loop_detected
      assert ctx.position == 256
    end

    test "oversized rdlength security check" do
      context = %{
        rdlength: 65536,
        max_allowed: 8192,
        record_type: :TXT
      }
      error = Error.new(:security_error, DNS.Message.Record, :rdlength_exceeds_limit, context)

      {message, ctx} = error
      assert message == "DNS.Message.Record Security Error"
      assert ctx.internal_reason == :rdlength_exceeds_limit
    end

    test "zone file parse error" do
      context = %{
        line_number: 42,
        content: "$ORIGIN invalid",
        expected: "valid domain name"
      }
      error = Error.new(:parse_error, DNS.Zone.FileParser, :invalid_origin, context)

      {message, ctx} = error
      assert message == "DNS Zone File Parse Error"
      assert ctx.line_number == 42
    end

    test "header format error" do
      context = %{
        expected_size: 12,
        actual_size: 10
      }
      error = Error.new(:format_error, DNS.Message.Header, :truncated_header, context)

      {message, ctx} = error
      assert message == "DNS.Message.Header Format Error"
      assert ctx.expected_size == 12
    end

    test "question validation error" do
      context = %{
        qname: "invalid..domain",
        qtype: 1,
        qclass: 1
      }
      error = Error.new(:validation_error, DNS.Message.Question, :invalid_qname, context)

      {message, _} = error
      # Question module uses fallback for validation_error
      assert message =~ "DNS"
      assert message =~ "Validation"
    end
  end

  describe "edge cases" do
    test "handles very long reason strings" do
      long_reason = String.duplicate("a", 10000)
      error = Error.new(:format_error, DNS.Message.Domain, long_reason)
      {_, context} = error
      assert context.internal_reason == long_reason
    end

    test "handles deeply nested context" do
      deep_context = Enum.reduce(1..10, %{value: "deep"}, fn _, acc ->
        %{nested: acc}
      end)
      error = Error.new(:format_error, DNS.Message.Domain, :test, deep_context)
      {_, context} = error
      assert context.nested != nil
    end

    test "handles special characters in reason" do
      special_reason = "test\n\t\r\\\"special"
      error = Error.new(:format_error, DNS.Message.Domain, special_reason)
      {_, context} = error
      assert context.internal_reason == special_reason
    end

    test "handles unicode in reason" do
      unicode_reason = "错误消息 🔥 エラー"
      error = Error.new(:format_error, DNS.Message.Domain, unicode_reason)
      {_, context} = error
      assert context.internal_reason == unicode_reason
    end

    test "handles binary reason" do
      binary_reason = <<0xFF, 0xFE, 0x00, 0x01>>
      error = Error.new(:format_error, DNS.Message.Domain, binary_reason)
      {_, context} = error
      assert context.internal_reason == binary_reason
    end

    test "handles empty string reason" do
      error = Error.new(:format_error, DNS.Message.Domain, "")
      {_, context} = error
      assert context.internal_reason == ""
    end

    test "handles large context map" do
      large_context = Map.new(1..1000, fn i -> {"key_#{i}", i} end)
      error = Error.new(:format_error, DNS.Message.Domain, :test, large_context)
      {_, context} = error
      assert map_size(context) == 1001  # 1000 + internal_reason
    end
  end

  describe "telemetry integration" do
    setup do
      # Ensure we can test telemetry execution
      Application.put_env(:dns, :detailed_errors, true)
      on_exit(fn -> Application.delete_env(:dns, :detailed_errors) end)
    end

    test "telemetry event is executed when enabled" do
      # Skip if telemetry app isn't started
      case Application.ensure_all_started(:telemetry) do
        {:ok, _} ->
          # Attach a handler to capture the event
          test_pid = self()
          ref = make_ref()

          :telemetry.attach(
            "test-handler-#{inspect(ref)}",
            [:ex_dns, :error, :detailed],
            fn event, measurements, metadata, _config ->
              send(test_pid, {:telemetry_event, event, measurements, metadata})
            end,
            nil
          )

          Application.put_env(:dns, :detailed_errors, true)
          Error.log_detailed_error(:format_error, DNS.Message.Domain, :test_reason, %{test: true})

          assert_receive {:telemetry_event, [:ex_dns, :error, :detailed], %{count: 1}, metadata}
          assert metadata.source == DNS.Message.Domain
          assert metadata.error_type == :format_error
          assert metadata.severity == :error

          :telemetry.detach("test-handler-#{inspect(ref)}")

        {:error, _} ->
          # Telemetry not available, just verify log_detailed_error works
          assert :ok = Error.log_detailed_error(:format_error, DNS.Message.Domain, :test_reason)
      end
    end

    test "telemetry event not executed when disabled" do
      case Application.ensure_all_started(:telemetry) do
        {:ok, _} ->
          test_pid = self()
          ref = make_ref()

          :telemetry.attach(
            "test-handler-disabled-#{inspect(ref)}",
            [:ex_dns, :error, :detailed],
            fn _event, _measurements, _metadata, _config ->
              send(test_pid, :telemetry_called)
            end,
            nil
          )

          Application.put_env(:dns, :detailed_errors, false)
          Error.log_detailed_error(:format_error, DNS.Message.Domain, :test_reason)

          refute_receive :telemetry_called, 100

          :telemetry.detach("test-handler-disabled-#{inspect(ref)}")

        {:error, _} ->
          # Telemetry not available, just verify log_detailed_error works when disabled
          Application.put_env(:dns, :detailed_errors, false)
          assert :ok = Error.log_detailed_error(:format_error, DNS.Message.Domain, :test_reason)
      end
    end
  end
end
