defmodule YellowDog.Tasks.Workers.SyncIpDatabaseWorkerTest do
  use ExUnit.Case, async: false

  alias YellowDog.Tasks.Job
  alias YellowDog.Tasks.Workers.SyncIpDatabaseWorker

  setup do
    previous = save_env([:ip_database_downloader, :ip_database_metadata, :ip_database_file_info])

    Application.put_env(:yellow_dog_tasks, :ip_database_downloader, fn
      :city -> {:ok, "/tmp/city.mmdb"}
      :country -> {:ok, "/tmp/country.mmdb"}
    end)

    Application.put_env(:yellow_dog_tasks, :ip_database_metadata, fn _type -> {:ok, %{}} end)
    Application.put_env(:yellow_dog_tasks, :ip_database_file_info, fn _type -> {:ok, %{size: 1}} end)

    on_exit(fn -> restore_env(previous) end)
  end

  test "syncs a city database and emits telemetry" do
    ref = attach_telemetry()

    assert :ok = SyncIpDatabaseWorker.perform(%Job{id: 123, args: %{"type" => "city"}})

    assert_receive {^ref, [:yellow_dog, :tasks, :sync, :start], %{task: :ip_city, source: "db-ip"}}
    assert_receive {^ref, [:yellow_dog, :tasks, :sync, :stop], %{task: :ip_city, source: "db-ip"}}
  end

  test "rejects invalid database types" do
    assert {:error, {:invalid_type, "bogus"}} =
             SyncIpDatabaseWorker.perform(%Job{id: 123, args: %{"type" => "bogus"}})
  end

  test "emits exception telemetry when sync fails" do
    Application.put_env(:yellow_dog_tasks, :ip_database_downloader, fn :city ->
      {:error, :offline}
    end)

    ref = attach_telemetry()

    assert {:error, :offline} = SyncIpDatabaseWorker.perform(%Job{id: 123, args: %{"type" => "city"}})

    assert_receive {^ref, [:yellow_dog, :tasks, :sync, :start], %{task: :ip_city, source: "db-ip"}}

    assert_receive {^ref, [:yellow_dog, :tasks, :sync, :exception],
                    %{task: :ip_city, source: "db-ip"}}
  end

  defp attach_telemetry do
    ref = make_ref()
    handler_id = {__MODULE__, ref}
    parent = self()

    :telemetry.attach_many(
      handler_id,
      [
        [:yellow_dog, :tasks, :sync, :start],
        [:yellow_dog, :tasks, :sync, :stop],
        [:yellow_dog, :tasks, :sync, :exception]
      ],
      fn event, _measurements, metadata, _config ->
        send(parent, {ref, event, Map.take(metadata, [:task, :source, :job_id])})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    ref
  end

  defp save_env(keys), do: Map.new(keys, &{&1, Application.get_env(:yellow_dog_tasks, &1)})

  defp restore_env(previous) do
    Enum.each(previous, fn
      {key, nil} -> Application.delete_env(:yellow_dog_tasks, key)
      {key, value} -> Application.put_env(:yellow_dog_tasks, key, value)
    end)
  end
end
