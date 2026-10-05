defmodule YellowDog.Management.LogStreamTest do
  use ExUnit.Case, async: false
  require Logger

  alias YellowDog.Management.LogStream

  setup do
    stream =
      start_supervised!(
        {LogStream, name: nil, handler_id: :management_log_stream_test, pubsub: nil}
      )

    %{stream: stream}
  end

  test "actual OTP Logger messages retain severity, source and real metadata", %{stream: stream} do
    marker = "management logger #{System.unique_integer([:positive])}"
    Logger.warning(marker, application: :yellow_dog_management, request_id: "request-123")
    Logger.flush()
    entry = await_entry(stream, marker)
    assert entry.level == :warning
    assert entry.app == "yellow_dog_management"
    assert entry.metadata["request_id"] == inspect("request-123")
    assert %DateTime{} = entry.timestamp
    assert entry.id > 0
    assert Enum.any?(LogStream.snapshot(), &(&1.message == marker))
  end

  test "the newest-first replay buffer is bounded and messages have byte limits", %{
    stream: stream
  } do
    for ordinal <- 1..1100 do
      send(stream, {:logger_event, event("message #{ordinal}")})
    end

    entries = LogStream.snapshot(stream)
    assert length(entries) == 1000
    assert hd(entries).message == "message 1100"
    assert List.last(entries).message == "message 101"
    assert Enum.map(entries, & &1.id) == Enum.sort(Enum.map(entries, & &1.id), :desc)

    send(stream, {:logger_event, event(String.duplicate("界", 10000))})
    [entry | _entries] = LogStream.snapshot(stream)
    assert byte_size(entry.message) <= 8192
    assert String.valid?(entry.message)
  end

  test "malformed observations cannot crash the log stream or expose arbitrary metadata", %{
    stream: stream
  } do
    send(stream, {:logger_event, %{level: :unrecognized, msg: :bad, meta: %{}}})
    send(stream, {:logger_event, %{level: :warning, msg: :bad, meta: :not_a_map}})
    send(stream, {:unrelated, :message})
    assert LogStream.snapshot(stream) == []

    send(stream, {:logger_event, put_in(event("bounded metadata"), [:meta, :secret], "private")})
    [entry] = LogStream.snapshot(stream)
    assert entry.metadata == %{}
    assert entry.app == "runtime"
    assert Process.alive?(stream)
  end

  test "handler restart replaces only a stale target and resumes real captures", %{stream: stream} do
    handler_id = :management_log_stream_restart_test

    {:ok, temporary} =
      LogStream.start_link(name: nil, handler_id: handler_id, pubsub: nil)

    Process.unlink(temporary)
    monitor = Process.monitor(temporary)
    Process.exit(temporary, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^temporary, :killed}

    replacement =
      start_supervised!(
        {LogStream, name: nil, handler_id: handler_id, pubsub: nil},
        id: :replacement_log_stream
      )

    marker = "recovered logger #{System.unique_integer([:positive])}"
    Logger.warning(marker)
    assert await_entry(replacement, marker).message == marker
    assert await_entry(stream, marker).message == marker
    assert {:ok, %{config: %{target: ^replacement}}} = :logger.get_handler_config(handler_id)
  end

  test "normal shutdown unregisters its handler without touching the active Management handler" do
    assert :ok = stop_supervised(LogStream)

    assert {:error, {:not_found, :management_log_stream_test}} =
             :logger.get_handler_config(:management_log_stream_test)

    assert {:ok, %{module: LogStream}} =
             :logger.get_handler_config(:yellow_dog_management_log_stream)
  end

  defp event(message) do
    %{level: :info, msg: {:string, message}, meta: %{time: System.system_time(:microsecond)}}
  end

  defp await_entry(stream, marker, remaining \\ 100)
  defp await_entry(_stream, _marker, 0), do: flunk("Logger observation was not captured")

  defp await_entry(stream, marker, remaining) do
    case Enum.find(LogStream.snapshot(stream), &(&1.message == marker)) do
      nil ->
        Process.sleep(10)
        await_entry(stream, marker, remaining - 1)

      entry ->
        entry
    end
  end
end
