defmodule Mix.Tasks.Dns.FetchRoot do
  @moduledoc """
  Fetch Root data from [iana]( https://data.iana.org/)

  """
  use Mix.Task

  @user_agent "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36"

  defp check_data_dir() do
    data_dir = DNS.Zone.RootHint.data_dir()

    unless File.exists?(data_dir) do
      IO.puts("data_dir not exists, create it #{data_dir}")
      File.mkdir_p!(data_dir)
    end
  end

  defp write_file(name, data) do
    IO.puts("wrtiting #{String.length(data)} bytes to file #{name}")
    data_dir = DNS.Zone.RootHint.data_dir()
    path = Path.join(data_dir, name)
    _ = File.write(path, data)
    :ok
  end

  defp fetch(url) do
    uri = URI.parse(url)
    headers = [{"User-Agent", @user_agent}, {"Host", uri.host}]

    case Tesla.get(url, headers: headers) do
      {:ok, %{status: 200, body: data}} ->
        {:ok, data}

      {:ok, %{status: status, body: data}} ->
        {:error, "fetch error: #{status}: #{data}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @shortdoc "Fetch Root data from [iana](https://data.iana.org/)"
  def run(_) do
    Mix.Task.run("app.start", [])

    check_data_dir()

    links = DNS.Zone.RootHint.links()

    for {name, url} <- links, is_binary(url) do
      case fetch(url) do
        {:ok, data} ->
          [_, file_name] = Regex.run(~r"\/([^/]+)$", url)
          _ = write_file(file_name, data)
          :ok

        {:error, reason} ->
          IO.puts("Error fetching #{name} #{url}: #{inspect(reason)}")
          :error
      end
    end

    root_trust_anchor = Keyword.get(links, :root_trust_anchor)
    {base_url, files} = Keyword.pop(root_trust_anchor, :url)

    for {name, file_name} <- files do
      file_url = "#{base_url}#{file_name}"
      IO.puts("Fetching #{name} from #{file_url}")

      case fetch(file_url) do
        {:ok, data} ->
          _ = write_file(file_name, data)
          :ok

        {:error, reason} ->
          IO.puts("Error fetching #{name} #{file_url}: #{inspect(reason)}")
          :error
      end
    end

    {_, 0} =
      System.cmd("sha256sum", ["-c", "checksums-sha256.txt"], cd: DNS.Zone.RootHint.data_dir())
  end
end
