defmodule YellowDog.Management.TaskArtifactsTest do
  use ExUnit.Case, async: false

  alias YellowDog.Management.{
    GeoIPArtifact,
    GeoIPDownload,
    GeoIPDownloadFixture,
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
    %{directory: directory}
  end

  test "catalog reads bound history in SQL and never hash file bytes", context do
    artifact = download(context.directory, :city)
    job = executing_job(:city, artifact.source_url)
    assert :ok = TaskArtifacts.publish(job, :city, artifact)
    timestamp = DateTime.add(DateTime.utc_now(), 10, :second)

    for number <- 1..25 do
      Repo.insert!(%GeoIPArtifact{
        digest: number |> Integer.to_string(16) |> String.pad_leading(64, "0"),
        kind: "city",
        format: "mmdb",
        path: "missing-history-#{number}",
        size: 1,
        source_url: "https://fixture.invalid/history",
        metadata: %{},
        inserted_at: timestamp
      })
    end

    owner = self()
    handler = "catalog-query-#{Ecto.UUID.generate()}"

    :ok =
      :telemetry.attach(
        handler,
        [:yellow_dog, :management, :repo, :query],
        &__MODULE__.record_catalog_query/4,
        owner
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    worker =
      spawn(fn ->
        receive do
          :catalog -> send(owner, {:catalog, TaskArtifacts.catalog()})
        end

        receive do
          :stop -> :ok
        end
      end)

    :erlang.trace_pattern({GeoIPDownload, :check_artifact, 1}, true, [:local])
    :erlang.trace(worker, true, [:call, {:tracer, self()}])

    on_exit(fn ->
      :erlang.trace_pattern({GeoIPDownload, :check_artifact, 1}, false, [:local])
      send(worker, :stop)
    end)

    send(worker, :catalog)
    assert_receive {:catalog, [%{selected: selected, versions: versions}, _]}, 2_000
    delivered = :erlang.trace_delivered(worker)
    assert_receive {:trace_delivered, ^worker, ^delivered}
    refute_received {:trace, ^worker, :call, {GeoIPDownload, :check_artifact, _}}
    assert_receive {:catalog_query, query, {:ok, %{num_rows: 21}}}
    assert query =~ "LIMIT"
    assert query =~ "OFFSET"
    assert length(versions) == 20
    assert selected.digest == artifact.digest
    refute Enum.any?(versions, &(&1.digest == artifact.digest))
    assert selected.available == nil
    assert selected.verification == :unverified
    assert Enum.map(versions, & &1.digest) == Enum.sort(Enum.map(versions, & &1.digest), :desc)
    send(worker, :stop)

    [%{page: 2, has_more: false, versions: next, selected: selected}, _] =
      TaskArtifacts.catalog(pages: %{"city" => 2})

    assert length(next) == 6
    assert selected.digest == artifact.digest
    assert MapSet.disjoint?(MapSet.new(versions, & &1.digest), MapSet.new(next, & &1.digest))
  end

  test "Country and City are durable independent catalog selections without a query server",
       context do
    assert is_nil(Process.whereis(YellowDog.Management.GeoIP))
    city = download(context.directory, :city)
    country = download(context.directory, :country)
    city_job = executing_job(:city, city.source_url)
    country_job = executing_job(:country, country.source_url)

    assert :ok = TaskArtifacts.publish(city_job, :city, city)
    assert :ok = TaskArtifacts.publish(country_job, :country, country)

    assert [
             %{kind: "city", selected: %{digest: city_digest, available: nil, format: "mmdb"}},
             %{kind: "country", selected: %{digest: country_digest, available: nil}}
           ] = TaskArtifacts.catalog()

    assert city_digest == city.digest
    assert country_digest == country.digest

    assert {:ok, %{metadata: %{"build_epoch" => 1_750_000_000}}} =
             TaskArtifacts.get(:country, country.digest)

    owner = self()

    fresh =
      Task.async(fn ->
        :ok = Ecto.Adapters.SQL.Sandbox.allow(Repo, owner, self())
        TaskArtifacts.catalog()
      end)

    assert Task.await(fresh) == TaskArtifacts.catalog()
    assert File.read!(city.path) == GeoIPFixtures.binary()

    assert %TaskReceipt{result: %{"format" => "mmdb", "digest" => ^city_digest}} =
             TaskArtifacts.receipt(city_job)
  end

  test "duplicate bytes reuse immutable metadata and retry receipts", context do
    first = download(context.directory, :city)
    job = executing_job(:city, first.source_url)
    assert :ok = TaskArtifacts.publish(job, :city, first)
    original = Repo.get!(GeoIPArtifact, first.digest)
    receipt = TaskArtifacts.receipt(job)
    selection = Repo.get!(GeoIPSelection, "city")
    assert :ok = TaskArtifacts.publish(job, :city, first)
    assert :ok = TaskArtifacts.restore_receipt(job, receipt)
    assert Repo.get!(GeoIPSelection, "city") == selection

    same = download(context.directory, :city)
    next_job = executing_job(:city, same.source_url)
    assert :ok = TaskArtifacts.publish(next_job, :city, same)
    assert Repo.get!(GeoIPArtifact, first.digest) == original
    assert Repo.aggregate(GeoIPArtifact, :count) == 1
    assert Repo.get!(GeoIPSelection, "city").job_id == next_job.id
  end

  test "an old receipt and an uncommitted older job cannot revert a newer selection", context do
    first = download(context.directory, :city)
    old = executing_job(:city, first.source_url)
    delayed = executing_job(:city, first.source_url)
    assert :ok = TaskArtifacts.publish(old, :city, first)
    receipt = TaskArtifacts.receipt(old)

    changed = :binary.replace(GeoIPFixtures.binary(), "London", "Londox")
    newer = download(context.directory, :city, changed)
    new_job = executing_job(:city, newer.source_url)
    assert :ok = TaskArtifacts.publish(new_job, :city, newer)
    selection = Repo.get!(GeoIPSelection, "city")
    assert :ok = TaskArtifacts.restore_receipt(old, receipt)
    assert :ok = TaskArtifacts.publish(old, :city, first)
    assert {:error, :selection_superseded} = TaskArtifacts.publish(delayed, :city, first)
    assert Repo.get!(GeoIPSelection, "city") == selection
    assert is_nil(TaskArtifacts.receipt(delayed))
    assert [%{kind: "city", versions: [_, _]}, _] = TaskArtifacts.catalog()
  end

  test "stale claims and cross-kind jobs cannot publish", context do
    artifact = download(context.directory, :city)
    job = executing_job(:city, artifact.source_url)

    assert {:error, :stale_job_claim} =
             TaskArtifacts.publish(%{job | attempt: job.attempt + 1}, :city, artifact)

    assert {:error, :invalid_job_kind} = TaskArtifacts.publish(job, :country, artifact)
    assert Repo.aggregate(GeoIPArtifact, :count) == 0
    assert is_nil(TaskArtifacts.receipt(job))
  end

  test "invalid files and filesystem failure leave a previous selection available", context do
    original = download(context.directory, :city)
    job = executing_job(:city, original.source_url)
    assert :ok = TaskArtifacts.publish(job, :city, original)
    selection = Repo.get!(GeoIPSelection, "city")
    next_job = executing_job(:city, original.source_url)
    missing = %{original | path: Path.join(context.directory, "missing.mmdb")}
    assert {:error, _} = TaskArtifacts.publish(next_job, :city, missing)

    assert {:error, :artifact_digest_mismatch} =
             TaskArtifacts.publish(next_job, :city, %{
               original
               | digest: String.duplicate("0", 64)
             })

    assert Repo.get!(GeoIPSelection, "city") == selection
    assert {:ok, %{available: true}} = TaskArtifacts.get(:city, original.digest)

    blocked_directory = Path.join(context.directory, "not-a-directory")
    File.write!(blocked_directory, "file")
    {url, _server} = GeoIPDownloadFixture.start(200, :zlib.gzip(GeoIPFixtures.binary()))
    assert {:error, _} = GeoIPDownload.fetch(:city, blocked_directory, url: url)
    assert Repo.get!(GeoIPSelection, "city") == selection
  end

  test "publication rejects wrong-kind, corrupt and oversized durable inputs", context do
    country = download(context.directory, :country)
    job = executing_job(:city, country.source_url)

    assert {:error, {:wrong_dataset, "GeoIP2-Country"}} =
             TaskArtifacts.publish(job, :city, country)

    path = Path.join(context.directory, "corrupt.mmdb")
    contents = "corrupt MMDB bytes"
    File.write!(path, contents)
    File.chmod!(path, 0o444)

    corrupt = %{
      country
      | path: path,
        size: byte_size(contents),
        digest: Base.encode16(:crypto.hash(:sha256, contents), case: :lower)
    }

    assert {:error, {:invalid_database, _reason}} = TaskArtifacts.publish(job, :city, corrupt)

    assert {:error, :invalid_artifact_size} =
             TaskArtifacts.publish(job, :city, %{corrupt | size: 256 * 1024 * 1024 + 1})

    assert Repo.aggregate(GeoIPArtifact, :count) == 0
    assert is_nil(Repo.get(GeoIPSelection, "city"))
    assert is_nil(TaskArtifacts.receipt(job))
  end

  test "a database publication failure rolls back metadata, selection and receipt", context do
    original = download(context.directory, :city)
    first = executing_job(:city, original.source_url)
    assert :ok = TaskArtifacts.publish(first, :city, original)
    selection = Repo.get!(GeoIPSelection, "city")
    changed = :binary.replace(GeoIPFixtures.binary(), "London", "Londox")
    candidate = download(context.directory, :city, changed)
    job = executing_job(:city, candidate.source_url)

    Repo.query!("""
    CREATE FUNCTION pg_temp.reject_artifact_selection() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN RAISE EXCEPTION 'fixture database publication failure'; END $$
    """)

    Repo.query!("""
    CREATE TRIGGER fixture_reject_selection BEFORE UPDATE ON management_geoip_selections
    FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_artifact_selection()
    """)

    assert {:error, :catalog_commit_failed} = TaskArtifacts.publish(job, :city, candidate)
    assert Repo.get!(GeoIPSelection, "city") == selection
    assert is_nil(Repo.get(GeoIPArtifact, candidate.digest))
    assert is_nil(TaskArtifacts.receipt(job))
    assert File.regular?(candidate.path)
    assert {:ok, %{available: true}} = TaskArtifacts.get("city", original.digest)
  end

  test "missing or changed selected files are unavailable despite durable metadata", context do
    artifact = download(context.directory, :city)
    job = executing_job(:city, artifact.source_url)
    assert :ok = TaskArtifacts.publish(job, :city, artifact)
    File.chmod!(artifact.path, 0o644)
    File.write!(artifact.path, :binary.replace(GeoIPFixtures.binary(), "London", "Londox"))
    File.chmod!(artifact.path, 0o444)
    assert {:error, :artifact_digest_mismatch} = TaskArtifacts.get(:city, artifact.digest)

    assert [%{selected: %{available: nil, verification: :unverified}}, _] =
             TaskArtifacts.catalog()

    File.rm!(artifact.path)
    assert {:error, {:file_error, :enoent}} = TaskArtifacts.get(:city, artifact.digest)

    assert {:error, {:file_error, :enoent}} =
             TaskArtifacts.restore_receipt(job, TaskArtifacts.receipt(job))

    assert Repo.get!(GeoIPSelection, "city").digest == artifact.digest
  end

  test "wrong-kind catalog lookups cannot expose another dataset", context do
    artifact = download(context.directory, :city)
    job = executing_job(:city, artifact.source_url)
    assert :ok = TaskArtifacts.publish(job, :city, artifact)
    assert {:error, :not_found} = TaskArtifacts.get(:country, artifact.digest)
    assert {:error, :invalid_kind} = TaskArtifacts.get(:asn, artifact.digest)
  end

  test "real queue failures retain history while the prior durable artifact stays available",
       context do
    artifact = download(context.directory, :city)
    first = executing_job(:city, artifact.source_url)
    assert :ok = TaskArtifacts.publish(first, :city, artifact)
    first |> Ecto.Changeset.change(state: "completed") |> Repo.update!()

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
    assert [%{}] = job.errors
    assert is_nil(TaskArtifacts.receipt(job))
    assert {:ok, %{available: true}} = TaskArtifacts.get(:city, artifact.digest)
  end

  test "real queue sync publishes a validated fixture without runtime activation", context do
    previous = System.get_env("YELLOW_DOG_MANAGEMENT_ARTIFACT_DIRECTORY")
    System.put_env("YELLOW_DOG_MANAGEMENT_ARTIFACT_DIRECTORY", context.directory)

    on_exit(fn ->
      if previous,
        do: System.put_env("YELLOW_DOG_MANAGEMENT_ARTIFACT_DIRECTORY", previous),
        else: System.delete_env("YELLOW_DOG_MANAGEMENT_ARTIFACT_DIRECTORY")
    end)

    {url, _server} = GeoIPDownloadFixture.start(200, :zlib.gzip(country_database()))

    {:ok, queued} =
      SyncGeoIPWorker.new(%{"task_key" => "ip_country", "source_url" => url}) |> Oban.insert()

    assert %{success: 1, failure: 0} =
             Oban.drain_queue(queue: :management_sync, with_safety: true)

    assert %TaskReceipt{result: %{"type" => "country", "digest" => digest}} =
             TaskArtifacts.receipt(queued)

    assert {:ok, %{available: true, format: "mmdb"}} = TaskArtifacts.get(:country, digest)
    assert is_nil(Process.whereis(YellowDog.Management.GeoIP))
  end

  defp executing_job(type, url) do
    # Insertion without queue uniqueness allows exercising two overlapping claims.
    job = %Oban.Job{
      worker: "YellowDog.Management.SyncGeoIPWorker",
      queue: "management_sync",
      args: %{"task_key" => "ip_#{type}", "source_url" => url},
      state: "executing",
      attempt: 1,
      max_attempts: 3,
      attempted_at: DateTime.utc_now()
    }

    Repo.insert!(job, prefix: "management_jobs")
  end

  def record_catalog_query(_event, _measurements, metadata, owner) do
    if metadata.source == "management_geoip_artifacts" and metadata.params == ["city", 21, 0],
      do: send(owner, {:catalog_query, metadata.query, metadata.result})
  end

  defp download(directory, type, contents \\ nil) do
    database = contents || if(type == :city, do: GeoIPFixtures.binary(), else: country_database())
    {url, _server} = GeoIPDownloadFixture.start(200, :zlib.gzip(database))
    {:ok, artifact} = GeoIPDownload.fetch(type, directory, url: url)
    artifact
  end

  defp country_database do
    metadata = %{
      "binary_format_major_version" => 2,
      "binary_format_minor_version" => 0,
      "build_epoch" => 1_750_000_000,
      "database_type" => "GeoIP2-Country",
      "description" => %{"en" => "Synthetic test database"},
      "ip_version" => 4,
      "languages" => ["en"],
      "node_count" => 1,
      "record_size" => 24
    }

    <<0, 0, 1, 0, 0, 1>> <>
      :binary.copy(<<0>>, 16) <>
      <<0xAB, 0xCD, 0xEF>> <> "MaxMind.com" <> encode_mmdb(metadata)
  end

  defp encode_mmdb(value) when is_map(value),
    do:
      <<7::3, map_size(value)::5>> <>
        Enum.map_join(value, fn {key, item} -> encode_mmdb(key) <> encode_mmdb(item) end)

  defp encode_mmdb(value) when is_binary(value), do: <<2::3, byte_size(value)::5>> <> value
  defp encode_mmdb(value) when is_integer(value), do: <<6::3, 4::5, value::32>>

  defp encode_mmdb(value) when is_list(value),
    do: <<0::3, length(value)::5, 4>> <> Enum.map_join(value, &encode_mmdb/1)
end
