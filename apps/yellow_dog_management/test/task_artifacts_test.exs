defmodule YellowDog.Management.TaskArtifactsTest do
  use ExUnit.Case, async: false

  alias YellowDog.Management.{
    Domain,
    GeoIP,
    GeoIPFixtures,
    GeoIPSelection,
    Repo,
    SyncGeoIPWorker,
    TaskArtifacts,
    TaskReceipt
  }

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok = Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    directory = Path.join(System.tmp_dir!(), "management-task-#{Ecto.UUID.generate()}")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    server = start_supervised!({GeoIP, name: nil, paths: %{}})
    :ok = Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), server)
    %{directory: directory, server: server}
  end

  test "validated bytes become durable selection and immutable receipt, restored on restart", %{
    directory: directory,
    server: server
  } do
    job = executing_job()
    artifact = artifact(directory)
    assert :ok = TaskArtifacts.activate(job, :city, artifact, server)
    assert {:ok, %{city: "London"}} = GeoIP.lookup("81.2.69.160", :city, server)
    assert %GeoIPSelection{digest: digest, job_id: job_id} = Repo.get!(GeoIPSelection, "city")
    assert digest == artifact.digest
    assert job_id == job.id
    assert %TaskReceipt{result: %{"digest" => ^digest}} = receipt = TaskArtifacts.receipt(job)
    assert :ok = TaskArtifacts.restore_receipt(job, receipt, server)
    owner = self()

    restored =
      Task.async(fn ->
        :ok = Ecto.Adapters.SQL.Sandbox.allow(Repo, owner, self())
        {:ok, restored} = GeoIP.start_link(name: nil, restore_selection: true)
        :ok = Ecto.Adapters.SQL.Sandbox.allow(Repo, owner, restored)
        GeoIPFixtures.wait_loaded(restored)
        result = GeoIP.lookup("81.2.69.160", :city, restored)
        GenServer.stop(restored)
        result
      end)

    assert {:ok, %{city: "London"}} = Task.await(restored)
  end

  test "invalid candidate or stale claim never replaces current path, data or selection", %{
    directory: directory,
    server: server
  } do
    first = executing_job()
    original = artifact(directory)
    assert :ok = TaskArtifacts.activate(first, :city, original, server)
    selection = Repo.get!(GeoIPSelection, "city")
    candidate = artifact(directory, "other.mmdb")
    stale = %{first | attempt: first.attempt + 1}
    assert {:error, :stale_job_claim} = TaskArtifacts.activate(stale, :city, candidate, server)
    assert Repo.get!(GeoIPSelection, "city") == selection

    assert {:error, :artifact_digest_mismatch} =
             TaskArtifacts.activate(
               first,
               :city,
               %{candidate | digest: String.duplicate("0", 64)},
               server
             )

    File.write!(candidate.path, "broken")
    assert {:error, _reason} = TaskArtifacts.activate(first, :city, candidate, server)
    assert Enum.at(GeoIP.info(server), 0).path == original.path
    assert {:ok, %{city: "London"}} = GeoIP.lookup("81.2.69.160", :city, server)
    assert Repo.get!(GeoIPSelection, "city") == selection
  end

  test "failure is retained by the real queue with no success receipt" do
    {:ok, queued} =
      SyncGeoIPWorker.new(%{
        "task_key" => "ip_city",
        "source_url" => "http://127.0.0.1:1/missing"
      })
      |> Oban.insert()

    assert %{failure: 1, success: 0} =
             Oban.drain_queue(queue: :management_sync, with_safety: true)

    job = Repo.get!(Oban.Job, queued.id, prefix: "management_jobs")
    assert job.state == "retryable"
    assert job.attempt == 1
    assert length(job.errors) == 1
    assert is_nil(TaskArtifacts.receipt(job))
    assert is_nil(Repo.get(GeoIPSelection, "city"))
  end

  test "a selected artifact cannot silently change across reload or restart", %{
    directory: directory,
    server: server
  } do
    job = executing_job()
    selected = artifact(directory)
    assert :ok = TaskArtifacts.activate(job, :city, selected, server)
    modified = :binary.replace(GeoIPFixtures.binary(), "London", "Londox")
    refute modified == GeoIPFixtures.binary()
    File.write!(selected.path, modified)
    assert {:error, :artifact_digest_mismatch} = GeoIP.reload(:city, server)
    assert {:ok, %{city: "London"}} = GeoIP.lookup("81.2.69.160", :city, server)
    {:ok, restarted} = GeoIP.start_link(name: nil, restore_selection: true)
    [city, _country] = GeoIPFixtures.wait_loaded(restarted)
    assert city.status == :error
    assert city.last_error == :artifact_digest_mismatch
    refute city.loaded
    GenServer.stop(restarted)
  end

  defp executing_job do
    {:ok, %{"id" => job_id}} =
      Domain.mutate("run_task", %{"key" => "ip_city"}, "operator", Ecto.UUID.generate())

    Repo.get!(Oban.Job, job_id, prefix: "management_jobs")
    |> Ecto.Changeset.change(state: "executing", attempt: 1, attempted_at: DateTime.utc_now())
    |> Repo.update!()
  end

  defp artifact(directory, filename \\ "city.mmdb") do
    path = GeoIPFixtures.write!(directory, filename)

    %{
      path: path,
      digest: :crypto.hash(:sha256, GeoIPFixtures.binary()) |> Base.encode16(case: :lower),
      size: File.stat!(path).size,
      source_url: "http://127.0.0.1/fixture.mmdb.gz",
      metadata: %{"database_type" => "GeoIP2-City"}
    }
  end
end
