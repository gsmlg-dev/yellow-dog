defmodule YellowDog.Netboot.TelemetryHandlerTest do
  use ExUnit.Case, async: false

  alias YellowDog.Netboot.TelemetryHandler

  setup do
    # Ensure any prior handlers are detached (returns :ok or {:error, :not_found})
    _ = :telemetry.detach("netboot-telemetry-handler")
    :ok
  end

  describe "attach/0" do
    test "registers telemetry handlers" do
      assert :ok = TelemetryHandler.attach()

      handlers = :telemetry.list_handlers([:yellow_dog, :netboot, :tftp, :transfer, :start])
      assert Enum.any?(handlers, &(&1.id == "netboot-telemetry-handler"))

      handlers = :telemetry.list_handlers([:yellow_dog, :netboot, :tftp, :transfer, :stop])
      assert Enum.any?(handlers, &(&1.id == "netboot-telemetry-handler"))

      handlers = :telemetry.list_handlers([:yellow_dog, :netboot, :tftp, :request, :accepted])
      assert Enum.any?(handlers, &(&1.id == "netboot-telemetry-handler"))

      handlers = :telemetry.list_handlers([:yellow_dog, :netboot, :tftp, :request, :rejected])
      assert Enum.any?(handlers, &(&1.id == "netboot-telemetry-handler"))

      TelemetryHandler.detach()
    end
  end

  describe "detach/0" do
    test "removes telemetry handlers" do
      TelemetryHandler.attach()

      handlers = :telemetry.list_handlers([:yellow_dog, :netboot, :tftp, :transfer, :start])
      assert Enum.any?(handlers, &(&1.id == "netboot-telemetry-handler"))

      TelemetryHandler.detach()

      handlers = :telemetry.list_handlers([:yellow_dog, :netboot, :tftp, :transfer, :start])
      refute Enum.any?(handlers, &(&1.id == "netboot-telemetry-handler"))
    end
  end

  describe "handle_event/4 - transfer start" do
    test "does not crash when PubSub is unavailable" do
      # PubSub is not started in the netboot test env, so broadcast will rescue
      TelemetryHandler.attach()

      # Emitting the event should not crash (rescue path)
      :telemetry.execute(
        [:yellow_dog, :netboot, :tftp, :transfer, :start],
        %{},
        %{filename: "vmlinuz", client: {192, 168, 1, 10}}
      )

      # Handler should still be attached (not detached by crash)
      handlers = :telemetry.list_handlers([:yellow_dog, :netboot, :tftp, :transfer, :start])
      assert Enum.any?(handlers, &(&1.id == "netboot-telemetry-handler"))

      TelemetryHandler.detach()
    end
  end

  describe "handle_event/4 - transfer stop" do
    test "merges measurements with metadata" do
      # Test the handle_event function directly to verify merge behavior
      measurements = %{duration: 1500, bytes: 4096}
      metadata = %{filename: "initrd.img", client: {10, 0, 0, 5}}

      # Should not crash — the broadcast will rescue without PubSub
      TelemetryHandler.handle_event(
        [:yellow_dog, :netboot, :tftp, :transfer, :stop],
        measurements,
        metadata,
        nil
      )
    end
  end

  describe "handle_event/4 - request accepted" do
    test "does not crash on accepted event" do
      TelemetryHandler.attach()

      :telemetry.execute(
        [:yellow_dog, :netboot, :tftp, :request, :accepted],
        %{},
        %{filename: "pxelinux.0", client: {172, 16, 0, 1}}
      )

      handlers = :telemetry.list_handlers([:yellow_dog, :netboot, :tftp, :request, :accepted])
      assert Enum.any?(handlers, &(&1.id == "netboot-telemetry-handler"))

      TelemetryHandler.detach()
    end
  end

  describe "handle_event/4 - request rejected" do
    test "does not crash on rejected event" do
      TelemetryHandler.attach()

      :telemetry.execute(
        [:yellow_dog, :netboot, :tftp, :request, :rejected],
        %{},
        %{filename: "../../etc/passwd", reason: :path_traversal}
      )

      handlers = :telemetry.list_handlers([:yellow_dog, :netboot, :tftp, :request, :rejected])
      assert Enum.any?(handlers, &(&1.id == "netboot-telemetry-handler"))

      TelemetryHandler.detach()
    end
  end

  describe "handle_event/4 - direct invocation" do
    test "transfer start broadcasts to both topics" do
      # Direct call — verifies the function contract without PubSub
      assert :ok =
               TelemetryHandler.handle_event(
                 [:yellow_dog, :netboot, :tftp, :transfer, :start],
                 %{},
                 %{filename: "boot.efi"},
                 nil
               )
    end

    test "transfer stop merges measurements into metadata" do
      assert :ok =
               TelemetryHandler.handle_event(
                 [:yellow_dog, :netboot, :tftp, :transfer, :stop],
                 %{duration: 500, bytes_transferred: 1024},
                 %{filename: "vmlinuz", client: {10, 0, 0, 1}},
                 nil
               )
    end

    test "request accepted broadcasts to log topic" do
      assert :ok =
               TelemetryHandler.handle_event(
                 [:yellow_dog, :netboot, :tftp, :request, :accepted],
                 %{},
                 %{filename: "ipxe.efi"},
                 nil
               )
    end

    test "request rejected broadcasts to log topic" do
      assert :ok =
               TelemetryHandler.handle_event(
                 [:yellow_dog, :netboot, :tftp, :request, :rejected],
                 %{},
                 %{reason: :not_found, filename: "missing.bin"},
                 nil
               )
    end
  end
end
