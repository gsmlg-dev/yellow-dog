defmodule YellowDog.Netboot.TelemetryHandler do
  @moduledoc """
  Bridges netboot telemetry events to PubSub for LiveView pages.

  Attaches to TFTP telemetry events and broadcasts on the
  `netboot:tftp` and `netboot:log` PubSub topics so the console
  Boot Log and TFTP pages receive real-time updates.
  """

  @tftp_topic "netboot:tftp"
  @log_topic "netboot:log"

  @doc "Attach all netboot telemetry handlers."
  def attach do
    events = [
      [:yellow_dog, :netboot, :tftp, :transfer, :start],
      [:yellow_dog, :netboot, :tftp, :transfer, :stop],
      [:yellow_dog, :netboot, :tftp, :request, :accepted],
      [:yellow_dog, :netboot, :tftp, :request, :rejected]
    ]

    :telemetry.attach_many(
      "netboot-telemetry-handler",
      events,
      &handle_event/4,
      nil
    )
  end

  @doc "Detach telemetry handlers."
  def detach do
    :telemetry.detach("netboot-telemetry-handler")
  end

  def handle_event(
        [:yellow_dog, :netboot, :tftp, :transfer, :start],
        _measurements,
        metadata,
        _config
      ) do
    broadcast(@tftp_topic, {:tftp_transfer_started, metadata})
    broadcast(@log_topic, {:tftp_transfer_started, metadata})
  end

  def handle_event(
        [:yellow_dog, :netboot, :tftp, :transfer, :stop],
        measurements,
        metadata,
        _config
      ) do
    data = Map.merge(metadata, measurements)
    broadcast(@tftp_topic, {:tftp_transfer_complete, data})
    broadcast(@log_topic, {:tftp_transfer_complete, data})
  end

  def handle_event(
        [:yellow_dog, :netboot, :tftp, :request, :accepted],
        _measurements,
        metadata,
        _config
      ) do
    broadcast(@log_topic, {:tftp_request_accepted, metadata})
  end

  def handle_event(
        [:yellow_dog, :netboot, :tftp, :request, :rejected],
        _measurements,
        metadata,
        _config
      ) do
    broadcast(@log_topic, {:tftp_request_rejected, metadata})
  end

  defp broadcast(topic, message) do
    Phoenix.PubSub.broadcast(
      YellowDog.Console.PubSub,
      topic,
      message
    )
  rescue
    _ -> :ok
  end
end
