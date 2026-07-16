defmodule YellowDog.Management.EventStoreHardeningTest do
  use ExUnit.Case, async: false

  alias YellowDog.Management.Event
  alias YellowDog.Management.EventStore
  alias YellowDog.Management.ManifestStore
  alias YellowDog.Management.Netmans
  alias YellowDog.Management.Servers
  alias YellowDog.ManagementCore

  setup do
    previous_data_dir = Application.fetch_env(:yellow_dog_management_core, :data_dir)
    previous_max_events = Application.fetch_env(:yellow_dog_management_core, :max_events)

    data_dir =
      Path.join(
        System.tmp_dir!(),
        "yellow-dog-event-hardening-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:yellow_dog_management_core, :data_dir, data_dir)
    Application.delete_env(:yellow_dog_management_core, :max_events)
    restart_management_children()

    on_exit(fn ->
      restore_env(:data_dir, previous_data_dir)
      restore_env(:max_events, previous_max_events)
      restart_management_children()
      File.rm_rf(data_dir)
    end)

    %{data_dir: data_dir}
  end

  test "malformed event fields and filename identities are never exposed", %{data_dir: data_dir} do
    Application.put_env(:yellow_dog_management_core, :max_events, 100)
    restart_child(EventStore)

    write_event(data_dir, "evt-1.json", event_map(1))

    metadata_21 =
      Enum.map(1..21, fn index ->
        %{
          "key" => Event.encode_scalar("key-#{index}"),
          "value" => Event.encode_scalar("value-#{index}")
        }
      end)

    write_event(data_dir, "evt-2.json", Map.put(event_map(2), "metadata", metadata_21))
    write_event(data_dir, "evt-3.json", Map.put(event_map(3), "id", "../evt-3"))
    write_event(data_dir, "evt-4.json", Map.put(event_map(4), "source_id", "../server"))
    write_event(data_dir, "evt-5.json", Map.put(event_map(5), "type", "netman_registered"))

    write_event(
      data_dir,
      "evt-6.json",
      Map.put(event_map(6), "message", String.duplicate("m", 129))
    )

    write_event(
      data_dir,
      "evt-7.json",
      Map.put(event_map(7), "source_id", String.duplicate("s", 129))
    )

    overlong_key = [
      %{
        "key" => Event.encode_scalar(String.duplicate("k", 65)),
        "value" => Event.encode_scalar("value")
      }
    ]

    write_event(data_dir, "evt-8.json", Map.put(event_map(8), "metadata", overlong_key))

    overlong_value = [
      %{
        "key" => Event.encode_scalar("key"),
        "value" => Event.encode_scalar(String.duplicate("v", 257))
      }
    ]

    write_event(data_dir, "evt-9.json", Map.put(event_map(9), "metadata", overlong_value))

    write_event(
      data_dir,
      "evt-10.json",
      Map.put(event_map(10), "occurred_at", "1969-12-31T23:59:59Z")
    )

    write_event(
      data_dir,
      "evt-11.json",
      Map.put(event_map(11), "occurred_at", "2026-07-16T00:00:00.123Z")
    )

    huge_sequence = 9_223_372_036_854_775_808

    huge_event =
      event_map(12)
      |> Map.put("id", "evt-#{huge_sequence}")
      |> Map.put("sequence", huge_sequence)

    write_event(data_dir, "evt-#{huge_sequence}.json", huge_event)
    write_event(data_dir, "evt-13.json", event_map(12))

    assert [%Event{id: "evt-1", sequence: 1}] = ManagementCore.list_events()
  end

  test "malformed newest candidates are skipped while filling the bounded valid slice", %{
    data_dir: data_dir
  } do
    Application.put_env(:yellow_dog_management_core, :max_events, 3)
    restart_child(EventStore)

    for sequence <- 1..3 do
      write_event(data_dir, "evt-#{sequence}.json", event_map(sequence))
    end

    for sequence <- 4..12 do
      write_event(data_dir, "evt-#{sequence}.json", %{"malformed" => sequence})
    end

    assert Enum.map(ManagementCore.list_events(), & &1.sequence) == [1, 2, 3]
  end

  test "partial malformed backfill traverses the event directory once", %{data_dir: data_dir} do
    Application.put_env(:yellow_dog_management_core, :max_events, 3)
    restart_child(EventStore)

    for sequence <- [1, 20, 21] do
      write_event(data_dir, "evt-#{sequence}.json", event_map(sequence))
    end

    for sequence <- 2..19 do
      write_event(data_dir, "evt-#{sequence}.json", %{"malformed" => sequence})
    end

    {events, traversal_count} = traced_event_list()

    assert Enum.map(events, & &1.sequence) == [1, 20, 21]
    assert traversal_count == 1
  end

  defp event_map(sequence) do
    Event.new(
      %{
        source: :server,
        source_id: "srv-valid",
        type: :server_registered,
        message: "Server registered"
      },
      sequence
    )
    |> Event.to_map(commit_token(sequence))
  end

  defp write_event(data_dir, filename, value) do
    path = Path.join([data_dir, "management", "events", filename])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(value))
  end

  defp commit_token(sequence) do
    :crypto.hash(:sha256, "event-fixture-#{sequence}")
    |> Base.url_encode64(padding: false)
  end

  defp restart_child(child_id) do
    :ok = Supervisor.terminate_child(YellowDog.ManagementCore.Supervisor, child_id)
    {:ok, _pid} = Supervisor.restart_child(YellowDog.ManagementCore.Supervisor, child_id)
  end

  defp traced_event_list do
    event_store_pid = Process.whereis(EventStore)
    :erlang.trace(event_store_pid, true, [:call])
    :erlang.trace_pattern({File, :ls, 1}, true, [])

    try do
      events = ManagementCore.list_events()
      {events, collect_file_ls_calls(event_store_pid, 0)}
    after
      :erlang.trace(event_store_pid, false, [:call])
      :erlang.trace_pattern({File, :ls, 1}, false, [])
    end
  end

  defp collect_file_ls_calls(event_store_pid, count) do
    receive do
      {:trace, ^event_store_pid, :call, {File, :ls, [_directory]}} ->
        collect_file_ls_calls(event_store_pid, count + 1)
    after
      0 -> count
    end
  end

  defp restart_management_children do
    Enum.each([Servers, Netmans, EventStore, ManifestStore], fn child_id ->
      :ok = Supervisor.terminate_child(YellowDog.ManagementCore.Supervisor, child_id)
    end)

    Enum.each([ManifestStore, EventStore, Servers, Netmans], fn child_id ->
      {:ok, _pid} = Supervisor.restart_child(YellowDog.ManagementCore.Supervisor, child_id)
    end)
  end

  defp restore_env(key, {:ok, value}),
    do: Application.put_env(:yellow_dog_management_core, key, value)

  defp restore_env(key, :error), do: Application.delete_env(:yellow_dog_management_core, key)
end
