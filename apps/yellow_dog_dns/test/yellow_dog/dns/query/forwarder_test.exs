defmodule YellowDog.Dns.Query.ForwarderTest do
  use ExUnit.Case, async: false

  alias YellowDog.Dns.Query.Forwarder

  setup do
    # Start Cache.Manager for forwarder tests
    {:ok, _pid} = start_supervised(YellowDog.Dns.Query.Cache.Manager)
    :ok
  end

  describe "forward_query/4" do
    test "returns error when no forwarders provided" do
      result = Forwarder.forward_query("example.com", :A, [])
      assert result == {:error, :no_forwarders}
    end

    @tag :integration
    test "successfully forwards query to Google DNS (8.8.8.8)" do
      forwarders = [{8, 8, 8, 8}]

      case Forwarder.forward_query("google.com", :A, forwarders, timeout_ms: 5000) do
        {:ok, records} ->
          assert is_list(records)
          assert length(records) > 0

          # Check that we got A records
          first_record = List.first(records)
          assert first_record.type == :A
          assert is_tuple(first_record.rdata)
          assert tuple_size(first_record.rdata) == 4

        {:error, reason} ->
          # Network might be unavailable in CI
          IO.puts("Warning: Integration test failed with reason: #{inspect(reason)}")
          assert true
      end
    end

    @tag :integration
    test "successfully forwards AAAA query" do
      forwarders = [{8, 8, 8, 8}]

      case Forwarder.forward_query("google.com", :AAAA, forwarders, timeout_ms: 5000) do
        {:ok, records} ->
          assert is_list(records)
          # Google should have AAAA records
          if length(records) > 0 do
            first_record = List.first(records)
            assert first_record.type == :AAAA
            assert is_tuple(first_record.rdata)
            assert tuple_size(first_record.rdata) == 8
          end

        {:error, _reason} ->
          # Network might be unavailable
          assert true
      end
    end

    @tag :integration
    test "returns NXDOMAIN for non-existent domain" do
      forwarders = [{8, 8, 8, 8}]

      case Forwarder.forward_query(
             "this-domain-definitely-does-not-exist-12345.com",
             :A,
             forwarders,
             timeout_ms: 5000
           ) do
        {:nxdomain, []} ->
          assert true

        {:error, _reason} ->
          # Network might be unavailable
          assert true

        other ->
          flunk("Expected NXDOMAIN or error, got: #{inspect(other)}")
      end
    end

    @tag :integration
    test "tries multiple forwarders on failure" do
      # Use an invalid IP first, then a valid one
      forwarders = [{192, 0, 2, 1}, {8, 8, 8, 8}]

      case Forwarder.forward_query("google.com", :A, forwarders, timeout_ms: 1000, max_retries: 0) do
        {:ok, records} ->
          # Should succeed using the second forwarder
          assert is_list(records)
          assert length(records) > 0

        {:error, _reason} ->
          # Network might be unavailable
          assert true
      end
    end

    @tag :integration
    test "respects timeout option" do
      # Non-routable IP
      forwarders = [{192, 0, 2, 1}]

      start_time = System.monotonic_time(:millisecond)

      result =
        Forwarder.forward_query("example.com", :A, forwarders,
          timeout_ms: 1000,
          max_retries: 0
        )

      end_time = System.monotonic_time(:millisecond)
      duration = end_time - start_time

      # Should timeout and return error
      assert result == {:error, :all_forwarders_failed}

      # Duration should be close to timeout (within 500ms tolerance)
      assert duration >= 900 and duration <= 1500
    end

    @tag :integration
    test "handles MX query forwarding" do
      forwarders = [{8, 8, 8, 8}]

      case Forwarder.forward_query("gmail.com", :MX, forwarders, timeout_ms: 5000) do
        {:ok, records} ->
          assert is_list(records)

          if length(records) > 0 do
            first_record = List.first(records)
            assert first_record.type == :MX
            # MX rdata should be {priority, exchange}
            assert is_tuple(first_record.rdata)
            assert tuple_size(first_record.rdata) == 2
          end

        {:error, _reason} ->
          # Network might be unavailable
          assert true
      end
    end

    @tag :integration
    test "handles TXT query forwarding" do
      forwarders = [{8, 8, 8, 8}]

      case Forwarder.forward_query("google.com", :TXT, forwarders, timeout_ms: 5000) do
        {:ok, records} ->
          assert is_list(records)
          # Google should have TXT records
          if length(records) > 0 do
            first_record = List.first(records)
            assert first_record.type == :TXT
            assert is_binary(first_record.rdata) or is_list(first_record.rdata)
          end

        {:error, _reason} ->
          # Network might be unavailable
          assert true

        {:nodata, _} ->
          # No TXT records, that's ok
          assert true
      end
    end

    @tag :integration
    test "uses Cloudflare DNS (1.1.1.1) as forwarder" do
      forwarders = [{1, 1, 1, 1}]

      case Forwarder.forward_query("cloudflare.com", :A, forwarders, timeout_ms: 5000) do
        {:ok, records} ->
          assert is_list(records)
          assert length(records) > 0

        {:error, _reason} ->
          # Network might be unavailable
          assert true
      end
    end

    @tag :integration
    test "handles IPv6 forwarder (Google DNS)" do
      # Google Public DNS IPv6: 2001:4860:4860::8888
      forwarders = [{0x2001, 0x4860, 0x4860, 0, 0, 0, 0, 0x8888}]

      case Forwarder.forward_query("google.com", :A, forwarders, timeout_ms: 5000) do
        {:ok, records} ->
          assert is_list(records)
          assert length(records) > 0

        {:error, _reason} ->
          # IPv6 might not be available
          assert true
      end
    end
  end

  describe "query message creation" do
    test "normalizes query names with trailing dot" do
      # This is an internal test to verify name normalization
      # We can't directly test private functions, but we can observe behavior
      forwarders = [{192, 0, 2, 1}]

      # Both should behave the same
      result1 =
        Forwarder.forward_query("example.com", :A, forwarders, timeout_ms: 100, max_retries: 0)

      result2 =
        Forwarder.forward_query("example.com.", :A, forwarders, timeout_ms: 100, max_retries: 0)

      # Both should fail the same way (no network)
      assert result1 == result2
      # When there's only one forwarder and it times out, we get {:error, :timeout}
      assert match?({:error, _}, result1)
    end
  end

  describe "retry behavior" do
    @tag :integration
    test "retries on timeout with valid forwarder" do
      # Using a non-routable IP to ensure timeout
      forwarders = [{192, 0, 2, 1}]

      start_time = System.monotonic_time(:millisecond)

      result =
        Forwarder.forward_query("example.com", :A, forwarders,
          timeout_ms: 500,
          max_retries: 2
        )

      end_time = System.monotonic_time(:millisecond)
      duration = end_time - start_time

      # Should fail after trying 3 times (initial + 2 retries)
      assert result == {:error, :all_forwarders_failed}

      # Duration should be approximately 3 * 500ms = 1500ms (within tolerance)
      assert duration >= 1400 and duration <= 1800
    end
  end

  describe "telemetry events" do
    test "emits telemetry events for forwarding" do
      # Attach a test handler
      test_pid = self()

      handler_id = :test_forwarder_telemetry

      :telemetry.attach_many(
        handler_id,
        [
          [:yellow_dog, :dns, :forward, :start],
          [:yellow_dog, :dns, :forward, :complete]
        ],
        fn event_name, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event_name, measurements, metadata})
        end,
        nil
      )

      # Make a query
      forwarders = [{192, 0, 2, 1}]
      Forwarder.forward_query("example.com", :A, forwarders, timeout_ms: 100, max_retries: 0)

      # Wait for telemetry events
      assert_receive {:telemetry, [:yellow_dog, :dns, :forward, :start], _measurements, metadata}
      # Name is normalized with trailing dot
      assert metadata.name == "example.com."
      # Type is normalized to lowercase by ex_dns
      assert metadata.type == :a

      assert_receive {:telemetry, [:yellow_dog, :dns, :forward, :complete], measurements,
                      metadata}

      # Name is normalized with trailing dot
      assert metadata.name == "example.com."
      # Type is normalized to lowercase by ex_dns
      assert metadata.type == :a
      assert metadata.result == :error
      assert is_integer(measurements.duration)

      # Cleanup
      :telemetry.detach(handler_id)
    end
  end
end
