defmodule YellowDog.Config do
  # https://hexdocs.pm/elixir/Agent.html
  use Agent
  require Logger

  def start_link(config) do
    Agent.start_link(fn -> config end, name: __MODULE__)
  end

  def config do
    Agent.get(__MODULE__, fn state -> state end)
  end

  def config(name) do
    Agent.get(__MODULE__, fn state -> Map.get(state, name) end)
  end

  @default_config %{
    "port" => 53,
    "logging-facility" => "local0",
    "logging-level" => "warning",
    "console" => true,
    "bind" => [:any],
    "ipv4-only" => false,
    "ipv6-only" => false,
    # False, until make Telemetry Module
    "telemetry" => false,
    "padding" => true,
    # RFC 9567, DNS Error Reporting
    "reporting-agent" => nil,
    "report-via-dns" => false
  }

  @config_file_home System.get_env("HOME") <> "/.yellowdog.toml"
  @config_file_etc "/etc/yellowdog.toml"
  def config_files do
    case System.fetch_env("YELLOWDOG_DNS_CONF_PATH") do
      {:ok, path} -> [path, @config_file_home, @config_file_etc]
      _ -> [@config_file_home, @config_file_etc]
    end
  end

  def default_config do
    @default_config
  end

  def load_config() do
    file =
      config_files()
      |> Enum.filter(&File.exists?(&1))
      |> List.first()

    if file == nil do
      Logger.warning("There is no configuration file found, use default settings.")
      default_config()
    else
      with {:ok, content} <- File.read(file),
           {:ok, config} <- Toml.decode(content) do
        Logger.info("Running from config file: `#{file}`:\n#{inspect(config, limit: :infinity)}")

        config
        |> Map.update!("bind", fn bind ->
          Enum.map(bind, fn
            "any" ->
              :any

            addr ->
              case :inet.parse_address(addr) do
                {:ok, a} -> a
                _ -> nil
              end
          end)
          |> Enum.filter(&(&1 != nil))
        end)
      else
        e ->
          exit("Configuration file invalid, #{inspect(e)}")
      end
    end
  end
end
