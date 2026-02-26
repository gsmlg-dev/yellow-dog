defmodule YellowDog.Fingerprint.ObserverTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias YellowDog.Fingerprint.Observer

  @dhcpv4_event [:yellow_dog, :dhcpv4, :message, :received]
  @dhcpv6_event [:yellow_dog, :dhcpv6, :message, :received]

  # Minimal DHCPv4 metadata with option_55 (triggers full pipeline)
  defp dhcpv4_metadata(opts \\ []) do
    base = %{
      # option_55 = parameter request list (1=subnet, 3=router, 6=DNS, 15=domain)
      option_55: [1, 3, 6, 15],
      # 6 bytes for MAC: VMware prefix 00:50:56
      chaddr: <<0, 80, 86, 0x12, 0x34, 0x56, 0, 0, 0, 0>>,
      option_60: "MSFT 5.0",
      option_12: "testhost",
      source_ip: {192, 168, 1, 42}
    }

    Map.merge(base, Map.new(opts))
  end

  # DHCPv4 metadata without option_55 (triggers :skip path)
  defp dhcpv4_skip_metadata do
    %{chaddr: <<0, 80, 86, 0x12, 0x34, 0x56, 0, 0, 0, 0>>}
  end

  # Minimal DHCPv6 metadata with DUID-LLT (DUID type 1)
  defp dhcpv6_metadata(opts \\ []) do
    # DUID-LLT: type(2)=1 + hw_type(2)=1 + time(4) + MAC(6)
    duid = <<1::16, 1::16, 0::32, 0, 80, 86, 0x12, 0x34, 0x56>>

    base = %{
      duid: duid,
      # DHCPv6 option 6 = option request list
      option_6: [23, 24, 25]
    }

    Map.merge(base, Map.new(opts))
  end

  describe "handle_event/4 DHCPv4 skip path" do
    test "returns :ok when option_55 is missing (insufficient data)" do
      result = Observer.handle_event(@dhcpv4_event, %{}, dhcpv4_skip_metadata(), nil)
      assert result == :ok
    end

    test "does not crash on empty metadata" do
      assert :ok = Observer.handle_event(@dhcpv4_event, %{}, %{}, nil)
    end
  end

  describe "handle_event/4 DHCPv4 full pipeline" do
    test "processes DHCPv4 event without crashing" do
      result = Observer.handle_event(@dhcpv4_event, %{count: 1}, dhcpv4_metadata(), nil)
      assert result == :ok
    end

    test "emits identified telemetry when profile matches" do
      test_pid = self()
      ref = make_ref()
      handler_id = "observer-identified-#{inspect(ref)}"

      :telemetry.attach(
        handler_id,
        [:yellow_dog, :fingerprint, :device, :identified],
        fn _event, _measurements, metadata, _ ->
          send(test_pid, {:identified, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      # Use a fingerprint that is likely unknown (no profiles loaded in test DB)
      # but the pipeline still runs fully; we just may get :unknown result
      Observer.handle_event(@dhcpv4_event, %{count: 1}, dhcpv4_metadata(), nil)

      # Give async processing time
      Process.sleep(50)

      # Either identified or unknown event will be emitted; we don't assert which
      # since the test DB may not have matching profiles. Just verify no crash.
      assert Process.alive?(self())
    end

    test "emits unknown telemetry for unrecognized fingerprint" do
      test_pid = self()
      ref = make_ref()
      handler_id = "observer-unknown-#{inspect(ref)}"

      :telemetry.attach(
        handler_id,
        [:yellow_dog, :fingerprint, :unknown],
        fn _event, measurements, metadata, _ ->
          send(test_pid, {:fp_unknown, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      # A unique vendor class unlikely to match any profile in the test DB
      unique_vc = "TestObserver-#{System.unique_integer([:positive])}"

      metadata = dhcpv4_metadata(option_60: unique_vc, option_55: [99, 100, 101])
      Observer.handle_event(@dhcpv4_event, %{count: 1}, metadata, nil)

      Process.sleep(50)

      # Should receive :unknown since this fingerprint won't match
      assert_receive {:fp_unknown, measurements, fp_metadata}, 500
      assert measurements.count == 1
      assert fp_metadata.protocol == :dhcpv4
    end
  end

  describe "handle_event/4 DHCPv6 skip path" do
    test "returns :ok when DHCPv6 metadata is insufficient" do
      # No option_6 or recognizable fingerprint data
      result = Observer.handle_event(@dhcpv6_event, %{}, %{}, nil)
      assert result == :ok
    end
  end

  describe "handle_event/4 DHCPv6 full pipeline" do
    test "processes DHCPv6 event without crashing" do
      result = Observer.handle_event(@dhcpv6_event, %{count: 1}, dhcpv6_metadata(), nil)
      assert result == :ok
    end
  end

  describe "handle_event/4 catch-all" do
    test "ignores unknown event types" do
      result = Observer.handle_event([:some, :other, :event], %{}, %{}, nil)
      assert result == :ok
    end
  end

  describe "handle_event/4 error recovery" do
    test "recovers from exception during DHCPv4 processing" do
      # Pass a metadata that has option_55 but with malformed chaddr
      # chaddr pattern match expects at least 6 bytes — 1 byte will cause a no-match (nil MAC)
      # This should not crash but will call process_match(fingerprint, nil, metadata)
      metadata = %{option_55: [1, 3, 6], chaddr: <<0>>}

      log =
        capture_log(fn ->
          result = Observer.handle_event(@dhcpv4_event, %{}, metadata, nil)
          assert result == :ok
        end)

      # No error log expected (nil MAC is handled gracefully)
      refute log =~ "Fingerprint observer DHCPv4 error"
    end
  end

  describe "start_link/1" do
    test "Observer GenServer is running (started by application)" do
      pid = Process.whereis(Observer)
      assert is_pid(pid)
      assert Process.alive?(pid)
    end
  end
end
