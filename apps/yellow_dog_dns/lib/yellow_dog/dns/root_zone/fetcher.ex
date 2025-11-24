defmodule YellowDog.Dns.RootZone.Fetcher do
  @moduledoc """
  Fetches DNS root zone from IANA and loads it as authoritative zone.

  This module downloads the root zone file from IANA's InterNIC service
  and parses it into a format that can be loaded by Zone.Manager.

  ## Configuration

  The fetch URL and interval can be configured via TOML:

      [dns.root_zone]
      strategy = "fetch"
      fetch_url = "https://www.internic.net/domain/root.zone"
      fetch_interval_hours = 24

  ## Usage

      # Fetch and load root zone
      {:ok, serial} = Fetcher.fetch_root_zone()

      # Schedule periodic fetching
      Fetcher.schedule_periodic_fetch(24 * 60 * 60 * 1000)  # 24 hours
  """

  require Logger
  alias YellowDog.Dns.Zone
  alias YellowDog.Telemetry

  @default_root_zone_url "https://www.internic.net/domain/root.zone"
  @default_timeout_ms 30_000
  @default_fetch_interval_hours 24

  @type fetch_opts :: [
          url: String.t(),
          timeout_ms: non_neg_integer(),
          temp_dir: String.t()
        ]

  @doc """
  Fetches the root zone from IANA and loads it into Zone.Manager.

  ## Options

  - `:url` - URL to fetch from (default: #{@default_root_zone_url})
  - `:timeout_ms` - HTTP timeout in milliseconds (default: #{@default_timeout_ms})
  - `:temp_dir` - Directory for temporary files (default: System.tmp_dir!)

  ## Returns

  - `{:ok, serial}` - Successfully fetched and loaded zone with serial number
  - `{:error, reason}` - Failed to fetch or load

  ## Examples

      # Fetch from default URL (requires Zone.Manager running)
      {:ok, serial} = Fetcher.fetch_root_zone()

      # Fetch from custom URL
      {:error, reason} = Fetcher.fetch_root_zone(url: "https://invalid.example.com/root.zone")
  """
  @spec fetch_root_zone(fetch_opts()) :: {:ok, non_neg_integer()} | {:error, any()}
  def fetch_root_zone(opts \\ []) do
    url = Keyword.get(opts, :url, @default_root_zone_url)
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    temp_dir = Keyword.get(opts, :temp_dir, System.tmp_dir!())

    span_id = Telemetry.start_span("dns.root_zone.fetch", %{url: url})

    Logger.info("Fetching root zone from #{url}")

    case do_fetch(url, timeout_ms) do
      {:ok, zone_data} ->
        case parse_and_load(zone_data, temp_dir) do
          {:ok, serial} = success ->
            Logger.info("Root zone fetched and loaded successfully", serial: serial)
            Telemetry.end_span(span_id, %{status: :success, serial: serial})
            success

          {:error, reason} = error ->
            Logger.error("Failed to parse/load root zone: #{inspect(reason)}")
            Telemetry.end_span(span_id, %{status: :failed, reason: reason})
            error
        end

      {:error, reason} = error ->
        Logger.error("Failed to fetch root zone: #{inspect(reason)}")
        Telemetry.end_span(span_id, %{status: :failed, reason: reason})
        error
    end
  end

  @doc """
  Parses fetched zone data and loads it into Zone.Manager.

  ## Parameters

  - `zone_data` - Raw zone file content as string
  - `temp_dir` - Optional temporary directory for zone file

  ## Returns

  - `{:ok, serial}` - Successfully parsed and loaded with serial number
  - `{:error, reason}` - Failed to parse or load
  """
  @spec parse_and_load(String.t(), String.t()) :: {:ok, non_neg_integer()} | {:error, any()}
  def parse_and_load(zone_data, temp_dir \\ System.tmp_dir!()) do
    # Write zone data to temporary file
    temp_file = Path.join(temp_dir, "root.zone.tmp")

    case File.write(temp_file, zone_data) do
      :ok ->
        # Load zone using Zone.Manager
        result =
          Zone.Manager.load_zone(".", file: temp_file, type: :master, ttl: 518_400)

        # Clean up temp file
        File.rm(temp_file)

        case result do
          {:ok, _} ->
            # Get serial from loaded zone
            case Zone.Manager.get_zone_metadata(".") do
              {:ok, metadata} -> {:ok, metadata.serial || 0}
              {:error, _} -> {:ok, 0}
            end

          {:error, _} = error ->
            error
        end

      {:error, reason} ->
        Logger.error("Failed to write temp zone file: #{inspect(reason)}")
        {:error, {:file_write_error, reason}}
    end
  end

  @doc """
  Schedules periodic root zone fetching.

  Sends a `:fetch_root_zone` message to the calling process
  after the specified interval.

  ## Parameters

  - `interval_ms` - Interval in milliseconds between fetches

  ## Returns

  - Timer reference

  ## Examples

      # Fetch every 24 hours
      ref = Fetcher.schedule_periodic_fetch(24 * 60 * 60 * 1000)
  """
  @spec schedule_periodic_fetch(non_neg_integer()) :: reference()
  def schedule_periodic_fetch(interval_ms) do
    Process.send_after(self(), :fetch_root_zone, interval_ms)
  end

  @doc """
  Gets the default fetch configuration.

  ## Returns

  Map with default fetch settings

  ## Examples

      iex> Fetcher.default_config()
      %{
        url: "https://www.internic.net/domain/root.zone",
        interval_hours: 24,
        timeout_ms: 30000
      }
  """
  @spec default_config() :: map()
  def default_config do
    %{
      url: @default_root_zone_url,
      interval_hours: @default_fetch_interval_hours,
      timeout_ms: @default_timeout_ms
    }
  end

  ## Private Functions

  defp do_fetch(url, timeout_ms) do
    # Use Req for HTTP fetching
    case Req.get(url, receive_timeout: timeout_ms) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_status, status}}

      {:error, exception} ->
        {:error, {:http_error, exception}}
    end
  rescue
    exception ->
      {:error, {:exception, exception}}
  end
end
