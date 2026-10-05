defmodule YellowDog.Management.BackupFiles do
  alias YellowDog.Management.{PostgresTools, Settings}
  @max_file 4 * 1024 * 1024 * 1024
  @max_total 8 * 1024 * 1024 * 1024
  @max_manifest 1_048_576
  @format "yellow-dog-management-backup"

  def directory(id) do
    {:ok, _uuid} = Ecto.UUID.cast(id)
    Path.join(Settings.backup_directory(), id)
  end

  def hash(path) do
    with {:ok, stat} <- File.lstat(path),
         true <- stat.type == :regular and stat.size <= @max_file do
      context =
        path
        |> File.stream!([], 1_048_576)
        |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))

      {:ok, %{digest: Base.encode16(:crypto.hash_final(context), case: :lower), size: stat.size}}
    else
      false -> {:error, :invalid_backup_file}
      {:error, reason} -> {:error, reason}
    end
  rescue
    _exception -> {:error, :backup_file_unreadable}
  end

  def copy_artifact(artifact, staging) do
    root = Settings.artifact_directory()
    expected_path = Path.join(root, "#{artifact.digest}.mmdb")

    with true <- artifact.path == expected_path,
         :ok <- File.mkdir_p(Path.join(staging, "artifacts")),
         :ok <- File.cp(artifact.path, Path.join(staging, "artifacts/#{artifact.digest}.mmdb")),
         {:ok, actual} <- hash(Path.join(staging, "artifacts/#{artifact.digest}.mmdb")),
         true <- actual.digest == artifact.digest and actual.size == artifact.size,
         :ok <- sync_file(Path.join(staging, "artifacts/#{artifact.digest}.mmdb")) do
      {:ok,
       %{
         "path" => "artifacts/#{artifact.digest}.mmdb",
         "digest" => artifact.digest,
         "size" => artifact.size
       }}
    else
      false -> {:error, :artifact_integrity}
      {:error, reason} -> {:error, reason}
    end
  end

  def seal(staging, manifest) do
    with :ok <- File.mkdir_p(Path.join(staging, "artifacts")),
         :ok <- File.write(Path.join(staging, "manifest.json"), Jason.encode!(manifest)),
         :ok <- sync_file(Path.join(staging, "manifest.json")),
         :ok <- sync_file(Path.join(staging, "database.dump")),
         :ok <- sync_directory(Path.join(staging, "artifacts")),
         {:ok, _output} <-
           PostgresTools.run("tar", [
             "--create",
             "--file",
             Path.join(staging, "package.tar"),
             "--directory",
             staging,
             "manifest.json",
             "database.dump",
             "artifacts"
           ]),
         :ok <- sync_file(Path.join(staging, "package.tar")),
         :ok <- sync_directory(staging),
         {:ok, archive} <- hash(Path.join(staging, "package.tar")) do
      {:ok, archive}
    end
  end

  def publish(staging, id) do
    with :ok <- File.rename(staging, directory(id)),
         :ok <- sync_directory(Settings.backup_directory()),
         do: :ok
  end

  def verify(id, expected_manifest, archive_digest) do
    directory = directory(id)

    with {:ok, %{type: :directory}} <- File.lstat(directory),
         {:ok, %{type: :regular, size: size}} when size <= @max_manifest <-
           File.lstat(Path.join(directory, "manifest.json")),
         {:ok, bytes} <- File.read(Path.join(directory, "manifest.json")),
         {:ok, manifest} <- Jason.decode(bytes),
         true <-
           manifest == expected_manifest and manifest["format"] == @format and
             manifest["id"] == id,
         {:ok, archive} <- hash(Path.join(directory, "package.tar")),
         true <- archive.digest == archive_digest,
         :ok <- verify_entries(directory, manifest),
         {:ok, _inventory} <-
           PostgresTools.run("pg_restore", ["--list", Path.join(directory, "database.dump")]) do
      {:ok,
       %{
         valid: true,
         level: "byte_integrity",
         dump_digest: manifest["dump"]["digest"],
         artifact_count: length(manifest["artifacts"]),
         row_count: manifest["row_count"]
       }}
    else
      false -> {:error, :backup_integrity}
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_backup_package}
    end
  rescue
    _exception -> {:error, :invalid_backup_package}
  end

  def manifest_format, do: @format

  def recover(id, job_id, label) do
    root = directory(id)

    with {:ok, %{type: :directory}} <- File.lstat(root),
         {:ok, %{type: :regular, size: size}} when size <= @max_manifest <-
           File.lstat(Path.join(root, "manifest.json")),
         {:ok, bytes} <- File.read(Path.join(root, "manifest.json")),
         {:ok, manifest} <- Jason.decode(bytes),
         true <- manifest["creating_job_id"] == job_id and manifest["label"] == label,
         {:ok, archive} <- hash(Path.join(root, "package.tar")),
         {:ok, _proof} <- verify(id, manifest, archive.digest) do
      {:ok, manifest, archive}
    else
      _invalid -> {:error, :published_backup_conflict}
    end
  end

  def sync_directory(path) do
    with {:ok, file} <- :file.open(String.to_charlist(path), [:read, :raw, :directory]) do
      try do
        :file.sync(file)
      after
        :file.close(file)
      end
    end
  end

  defp sync_file(path) do
    with :ok <- File.chmod(path, 0o400),
         {:ok, file} <- :file.open(String.to_charlist(path), [:read, :raw, :binary]) do
      try do
        :file.sync(file)
      after
        :file.close(file)
      end
    end
  end

  defp verify_entries(directory, manifest) do
    entries = [manifest["dump"] | manifest["artifacts"]]

    Enum.reduce_while(entries, 0, fn entry, total ->
      path = entry["path"]

      allowed =
        path == "database.dump" or
          (is_binary(entry["digest"]) and
             Regex.match?(~r/^[a-f0-9]{64}$/, entry["digest"]) and
             path == "artifacts/#{entry["digest"]}.mmdb")

      expected_digest = entry["digest"]
      expected_size = entry["size"]

      case allowed && hash(Path.join(directory, path)) do
        {:ok, actual}
        when actual.digest == expected_digest and actual.size == expected_size and
               total + actual.size <= @max_total ->
          {:cont, total + actual.size}

        _invalid ->
          {:halt, {:error, :backup_integrity}}
      end
    end)
    |> case do
      total when is_integer(total) -> :ok
      error -> error
    end
  end
end
