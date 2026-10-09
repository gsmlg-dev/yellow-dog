defmodule YellowDog.Worker.Bootstrap do
  @moduledoc "Machine-local settings, deliberately separate from the shared WorkerPlan."

  @local ~w(data_dir source worker_id)
  @managed ~w(data_dir management_url token worker_id)
  @optional ~w(tls_ca_file tls_cert_file tls_key_file poll_interval_ms)

  def load(path) when is_binary(path) do
    with {:ok, %{size: size, type: :regular}} when size <= 16_384 <- File.lstat(path),
         {:ok, text} <- File.read(path),
         {:ok, config} <- Toml.decode(text),
         {:ok, options} <- settings(config, Path.dirname(Path.expand(path))) do
      {:ok, options}
    else
      _ -> {:error, :invalid_bootstrap}
    end
  end

  def load(_), do: {:error, :missing_bootstrap_path}

  defp settings(config, root) do
    keys = Map.keys(config)
    local? = Enum.sort(keys) == @local

    managed? =
      Enum.all?(@managed, &Map.has_key?(config, &1)) and keys -- (@managed ++ @optional) == []

    with true <- local? or managed?,
         true <-
           Enum.all?(Map.delete(config, "poll_interval_ms"), fn {_key, value} ->
             is_binary(value) and byte_size(value) in 1..4096
           end),
         {:ok, _} <-
           YellowDog.ConfigSpec.normalize_plan(%{
             "schema_version" => 1,
             "worker_id" => config["worker_id"],
             "revision" => 1,
             "services" => [],
             "resources" => []
           }) do
      base = [worker_id: config["worker_id"], data_dir: Path.expand(config["data_dir"], root)]

      if local? do
        {:ok, base ++ [source: Path.expand(config["source"], root)]}
      else
        with true <- valid_url?(config["management_url"]),
             true <- Regex.match?(~r/\A[A-Za-z0-9_-]{32,256}\z/, config["token"]),
             interval = Map.get(config, "poll_interval_ms", 10_000),
             true <- is_integer(interval) and interval in 100..15_000,
             true <-
               Map.has_key?(config, "tls_cert_file") == Map.has_key?(config, "tls_key_file"),
             {:ok, tls} <- tls_files(config, root) do
          {:ok,
           base ++
             [
               source: nil,
               connection:
                 [
                   management_url: config["management_url"],
                   token: config["token"],
                   poll_interval_ms: interval
                 ] ++ tls
             ]}
        end
      end
    else
      _ -> {:error, :invalid_bootstrap}
    end
  end

  def valid_url?(url) when is_binary(url) do
    uri = URI.parse(url)

    uri.userinfo == nil and uri.query == nil and uri.fragment == nil and
      uri.path in [nil, "", "/"] and is_binary(uri.host) and uri.host != "" and
      (uri.scheme == "https" or
         (uri.scheme == "http" and uri.host in ["127.0.0.1", "::1", "localhost"])) and
      is_integer(uri.port) and uri.port in 1..65535
  rescue
    _ -> false
  end

  def valid_url?(_), do: false

  defp tls_files(config, root) do
    Enum.reduce_while(~w(tls_ca_file tls_cert_file tls_key_file)a, {:ok, []}, fn key,
                                                                                 {:ok, acc} ->
      case config[Atom.to_string(key)] do
        nil ->
          {:cont, {:ok, acc}}

        value ->
          path = Path.expand(value, root)

          if File.regular?(path),
            do: {:cont, {:ok, [{key, path} | acc]}},
            else: {:halt, {:error, :invalid_tls_file}}
      end
    end)
  end
end
