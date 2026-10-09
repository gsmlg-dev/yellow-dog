alias YellowDog.Management.{Domain, WorkerConnections}

path = System.fetch_env!("YELLOW_DOG_WORKER_BOOTSTRAP")
directory = Path.dirname(path)
File.mkdir_p!(directory)
File.chmod!(directory, 0o700)

unless File.exists?(path) do
  {:ok, %{"worker" => worker, "token" => token}} = WorkerConnections.create("Devenv Worker")
  url = "http://127.0.0.1:#{System.fetch_env!("YELLOW_DOG_MANAGEMENT_PORT")}"
  bootstrap = WorkerConnections.bootstrap(worker, token, url)
  File.write!(path <> ".tmp", bootstrap)
  File.chmod!(path <> ".tmp", 0o600)
  File.rename!(path <> ".tmp", path)
end

{:ok, bootstrap} = Toml.decode_file(path)

case Domain.get_worker(bootstrap["worker_id"]) do
  {:ok, _worker} ->
    IO.puts("devenv_worker=#{bootstrap["worker_id"]}")

  {:error, _error} ->
    raise "Devenv Worker is missing from Management; check #{path} and the database"
end
