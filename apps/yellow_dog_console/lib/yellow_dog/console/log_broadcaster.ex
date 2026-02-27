defmodule YellowDog.Console.LogBroadcaster do
  @moduledoc """
  Broadcasts telemetry log events to connected LiveView processes via PubSub.

  This GenServer attaches to all log-level telemetry events (debug, info, warning, error)
  and broadcasts them to the "logs:stream" PubSub topic. LiveView processes can subscribe
  to this topic to receive real-time log updates.

  ## Usage

  Start the broadcaster as part of the Console application supervisor:

      children = [
        YellowDog.Console.LogBroadcaster,
        # ...
      ]

  LiveViews subscribe in mount/3:

      def mount(_params, _session, socket) do
        if connected?(socket) do
          Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, "logs:stream")
        end
        {:ok, socket}
      end

  And receive events in handle_info/2:

      def handle_info({:log_event, level, measurements, metadata}, socket) do
        # Process the log event
        {:noreply, socket}
      end
  """

  use GenServer

  @pubsub YellowDog.Console.PubSub
  @topic "logs:stream"

  @doc """
  Starts the LogBroadcaster GenServer.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the PubSub topic for log streaming.
  """
  @spec topic() :: String.t()
  def topic, do: @topic

  @impl true
  def init(_opts) do
    :telemetry.attach_many(
      "yellow-dog-log-broadcaster",
      [
        [:yellow_dog, :log, :debug],
        [:yellow_dog, :log, :info],
        [:yellow_dog, :log, :warning],
        [:yellow_dog, :log, :error]
      ],
      &__MODULE__.handle_log_event/4,
      %{}
    )

    {:ok, %{}}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, _state) do
    :telemetry.detach("yellow-dog-log-broadcaster")
    :ok
  end

  @doc false
  def handle_log_event(event, measurements, metadata, _config) do
    level = List.last(event)

    Phoenix.PubSub.broadcast(
      @pubsub,
      @topic,
      {:log_event, level, measurements, metadata}
    )
  end
end
