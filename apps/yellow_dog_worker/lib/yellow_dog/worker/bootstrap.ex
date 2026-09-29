defmodule YellowDog.Worker.Bootstrap do
  @moduledoc "Machine-local settings, deliberately separate from the shared WorkerPlan."

  def load(path) when is_binary(path) do
    with {:ok, %{size: size, type: :regular}} when size <= 4096 <- File.lstat(path),
         {:ok, text} <- File.read(path),
         {:ok, config} <- Toml.decode(text),
         true <- Enum.sort(Map.keys(config)) == ~w(data_dir source worker_id),
         true <- Enum.all?(Map.values(config), &(is_binary(&1) and byte_size(&1) in 1..4096)),
         {:ok, _} <-
           YellowDog.ConfigSpec.normalize_plan(%{
             "schema_version" => 1,
             "worker_id" => config["worker_id"],
             "revision" => 1,
             "services" => [],
             "resources" => []
           }) do
      root = Path.dirname(Path.expand(path))

      {:ok,
       [
         worker_id: config["worker_id"],
         data_dir: Path.expand(config["data_dir"], root),
         source: Path.expand(config["source"], root)
       ]}
    else
      failure -> {:error, {:invalid_bootstrap, failure}}
    end
  end

  def load(_), do: {:error, :missing_bootstrap_path}
end
