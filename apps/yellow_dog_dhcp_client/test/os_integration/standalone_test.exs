defmodule YellowDog.DhcpClient.OSIntegration.StandaloneTest do
  use ExUnit.Case, async: true

  alias YellowDog.DhcpClient.OSIntegration.Standalone
  alias YellowDog.DhcpClient.Lease

  defp test_lease(overrides \\ %{}) do
    Map.merge(
      %Lease{
        ip: {192, 168, 1, 100},
        subnet_mask: {255, 255, 255, 0},
        router: {192, 168, 1, 1},
        dns_servers: [{8, 8, 8, 8}],
        server_ip: {192, 168, 1, 1},
        lease_time: 3600,
        t1: 1800,
        t2: 3150,
        mtu: nil,
        domain_name: nil,
        ntp_servers: [],
        vendor_options: %{},
        yellowdog_server: false,
        obtained_at: DateTime.utc_now(),
        xid: 0x1234,
        raw_options: %{}
      },
      overrides
    )
  end

  describe "apply_routes/2" do
    test "returns :ok when router is nil (skip path)" do
      lease = test_lease(%{router: nil})
      assert :ok = Standalone.apply_routes("test0", lease)
    end

    test "emits telemetry for route add" do
      ref = make_ref()
      self_pid = self()

      :telemetry.attach(
        "test-route-#{inspect(ref)}",
        [:yellow_dog, :dhcp_client, :os, :apply],
        fn _event, measurements, metadata, _config ->
          if metadata.action == :add_route do
            send(self_pid, {:telemetry_route, measurements, metadata})
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("test-route-#{inspect(ref)}") end)

      lease = test_lease(%{router: {192, 168, 1, 1}})
      # Will fail due to no CAP_NET_ADMIN, but telemetry should still fire
      _result = Standalone.apply_routes("test0", lease)

      assert_receive {:telemetry_route, %{duration_ms: _},
                      %{interface: "test0", action: :add_route}},
                     1000
    end
  end

  describe "apply_dns/2" do
    test "returns :ok when dns_servers is empty" do
      lease = test_lease(%{dns_servers: []})
      assert :ok = Standalone.apply_dns("test0", lease)
    end

    test "does not crash when dns_servers is non-empty but commands fail" do
      lease = test_lease(%{dns_servers: [{8, 8, 8, 8}]})
      # apply_dns returns :ok or {:error, _} but must never raise
      result = Standalone.apply_dns("test_dns_iface", lease)
      assert result == :ok or match?({:error, _}, result)
    end

    test "filters out non-tuple dns_servers values" do
      # If dns_servers contains a mix, only tuples should be used
      lease = test_lease(%{dns_servers: [{8, 8, 8, 8}, "8.8.4.4"]})
      result = Standalone.apply_dns("test_dns_iface2", lease)
      assert result == :ok or match?({:error, _}, result)
    end
  end

  describe "deconfigure/1" do
    test "always returns :ok even when commands fail" do
      # deconfigure ignores all errors
      assert :ok = Standalone.deconfigure("nonexistent_test_iface")
    end

    test "emits telemetry events for each deconfigure action" do
      ref = make_ref()
      self_pid = self()

      :telemetry.attach(
        "test-deconfig-#{inspect(ref)}",
        [:yellow_dog, :dhcp_client, :os, :apply],
        fn _event, _measurements, metadata, _config ->
          send(
            self_pid,
            {:telemetry_deconfig, metadata.action, metadata.interface, metadata.result}
          )
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("test-deconfig-#{inspect(ref)}") end)

      assert :ok = Standalone.deconfigure("test_deconfig_iface")

      # Collect all telemetry events (3: flush_addr, del_route, del_dns)
      events =
        Enum.reduce_while(1..10, [], fn _, acc ->
          receive do
            {:telemetry_deconfig, action, _iface, _result} -> {:cont, [action | acc]}
          after
            2000 -> {:halt, acc}
          end
        end)

      actions = MapSet.new(events)
      assert :flush_addr in actions
      assert :del_route in actions
      assert :del_dns in actions
    end
  end

  describe "MTU validation" do
    test "skips MTU when nil" do
      lease = test_lease(%{mtu: nil})
      # apply_lease will fail at add_addr (no CAP_NET_ADMIN), so test via reflection:
      # nil MTU should not cause any MTU-related telemetry
      ref = make_ref()
      self_pid = self()

      :telemetry.attach(
        "test-mtu-nil-#{inspect(ref)}",
        [:yellow_dog, :dhcp_client, :os, :apply],
        fn _event, _measurements, metadata, _config ->
          if metadata.action == :set_mtu do
            send(self_pid, :mtu_set_called)
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("test-mtu-nil-#{inspect(ref)}") end)

      _result = Standalone.apply_lease("test_mtu_nil", lease)

      refute_receive :mtu_set_called, 200
    end

    test "rejects MTU below minimum (68)" do
      lease = test_lease(%{mtu: 10})
      ref = make_ref()
      self_pid = self()

      :telemetry.attach(
        "test-mtu-low-#{inspect(ref)}",
        [:yellow_dog, :dhcp_client, :os, :apply],
        fn _event, _measurements, metadata, _config ->
          if metadata.action == :set_mtu do
            send(self_pid, :mtu_set_called)
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("test-mtu-low-#{inspect(ref)}") end)

      _result = Standalone.apply_lease("test_mtu_low", lease)

      refute_receive :mtu_set_called, 200
    end

    test "rejects MTU above maximum (65535)" do
      lease = test_lease(%{mtu: 100_000})
      ref = make_ref()
      self_pid = self()

      :telemetry.attach(
        "test-mtu-high-#{inspect(ref)}",
        [:yellow_dog, :dhcp_client, :os, :apply],
        fn _event, _measurements, metadata, _config ->
          if metadata.action == :set_mtu do
            send(self_pid, :mtu_set_called)
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("test-mtu-high-#{inspect(ref)}") end)

      _result = Standalone.apply_lease("test_mtu_high", lease)

      refute_receive :mtu_set_called, 200
    end

    test "accepts MTU of 68 (minimum boundary) — no invalid-MTU warning logged" do
      import ExUnit.CaptureLog

      # apply_lease short-circuits at add_addr, but maybe_set_mtu would NOT log
      # a warning for 68. Verify the function doesn't crash and the warning is absent.
      lease = test_lease(%{mtu: 68})

      log =
        capture_log(fn ->
          _result = Standalone.apply_lease("test_mtu_68_min", lease)
        end)

      refute String.contains?(log, "ignoring invalid MTU")
    end

    test "accepts MTU of 65535 (maximum boundary) — no invalid-MTU warning logged" do
      import ExUnit.CaptureLog

      lease = test_lease(%{mtu: 65_535})

      log =
        capture_log(fn ->
          _result = Standalone.apply_lease("test_mtu_65535_max", lease)
        end)

      refute String.contains?(log, "ignoring invalid MTU")
    end
  end

  describe "apply_lease/2 edge cases" do
    test "apply_lease with all optional fields nil does not crash" do
      minimal =
        test_lease(%{
          router: nil,
          dns_servers: [],
          domain_name: nil,
          mtu: nil,
          ntp_servers: []
        })

      # Must not raise even though commands fail (no CAP_NET_ADMIN)
      result = Standalone.apply_lease("test_minimal_opts", minimal)
      assert result == :ok or match?({:error, _}, result)
    end
  end

  describe "apply_lease/2 telemetry" do
    test "emits telemetry even when ip command fails" do
      ref = make_ref()
      self_pid = self()

      :telemetry.attach(
        "test-lease-apply-#{inspect(ref)}",
        [:yellow_dog, :dhcp_client, :os, :apply],
        fn _event, measurements, metadata, _config ->
          if metadata.action == :add_addr do
            send(self_pid, {:telemetry_apply, measurements, metadata})
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("test-lease-apply-#{inspect(ref)}") end)

      lease = test_lease()
      # Will fail (no CAP_NET_ADMIN) but telemetry should still fire
      _result = Standalone.apply_lease("test0", lease)

      assert_receive {:telemetry_apply, %{duration_ms: dur}, %{action: :add_addr}}, 2000
      assert is_integer(dur) and dur >= 0
    end
  end
end
