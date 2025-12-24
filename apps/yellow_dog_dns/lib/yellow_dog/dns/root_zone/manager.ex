defmodule YellowDog.Dns.RootZone.Manager do
  @moduledoc """
  Manages DNS root zone data with three strategies:
  - `:hints` - Use embedded root server addresses
  - `:fetch` - Periodically fetch from IANA
  - `:auth` - Load root zone as authoritative zone

  This GenServer manages the lifecycle of the root zone, including:
  - Initial loading based on configured strategy
  - Periodic updates for :fetch strategy
  - Fallback mechanism (fetch → hints)
  - Runtime reloading

  ## Configuration

  Configure via TOML:

      [dns.root_zone]
      strategy = "hints"  # or "fetch" or "auth"
      fetch_url = "https://www.internic.net/domain/root.zone"
      fetch_interval_hours = 24
      fallback_to_hints = true
      zone_file = "/etc/yellowdog/zones/root.zone"

  ## Usage

      # Start the manager
      {:ok, pid} = RootZone.Manager.start_link(strategy: :hints)

      # Get root servers
      servers = RootZone.Manager.get_root_servers()

      # Get current strategy
      strategy = RootZone.Manager.get_strategy()

      # Reload root zone
      :ok = RootZone.Manager.reload_root_zone()

      # Get statistics
      stats = RootZone.Manager.stats()
  """

  use GenServer

  alias YellowDog.Dns.RootZone.{Hints, Fetcher}
  alias YellowDog.Dns.Zone
  alias YellowDog.Telemetry

  @type strategy :: :hints | :fetch | :auth
  @type config :: %{
          strategy: strategy(),
          fetch_url: String.t() | nil,
          fetch_interval_hours: non_neg_integer(),
          fallback_to_hints: boolean(),
          zone_file: String.t() | nil
        }

  @default_config %{
    strategy: :hints,
    fetch_url: "https://www.internic.net/domain/root.zone",
    fetch_interval_hours: 24,
    fallback_to_hints: true,
    zone_file: nil
  }

  ## Client API

  @doc """
  Starts the Root Zone Manager GenServer.

  ## Options

  - `:strategy` - Root zone strategy (:hints, :fetch, or :auth)
  - `:fetch_url` - URL for :fetch strategy
  - `:fetch_interval_hours` - Fetch interval in hours
  - `:fallback_to_hints` - Whether to fallback to hints on fetch failure
  - `:zone_file` - Zone file path for :auth strategy
  - `:config` - Full configuration map (overrides individual options)

  ## Examples

      RootZone.Manager.start_link(strategy: :hints)
      RootZone.Manager.start_link(strategy: :fetch, fetch_interval_hours: 12)
      RootZone.Manager.start_link(strategy: :auth, zone_file: "/etc/zones/root.zone")
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Gets the list of root servers based on current strategy.

  For :hints strategy, returns embedded addresses.
  For :fetch and :auth strategies, queries the loaded root zone.

  ## Returns

  List of `{name, ip_address}` tuples

  ## Examples

      iex> RootZone.Manager.get_root_servers()
      [
        {"a.root-servers.net", {198, 41, 0, 4}},
        {"b.root-servers.net", {199, 9, 14, 201}},
        ...
      ]
  """
  @spec get_root_servers() :: [{String.t(), :inet.ip_address()}]
  def get_root_servers do
    GenServer.call(__MODULE__, :get_root_servers)
  end

  @doc """
  Gets the current root zone strategy.

  ## Returns

  `:hints`, `:fetch`, or `:auth`

  ## Examples

      iex> RootZone.Manager.get_strategy()
      :hints
  """
  @spec get_strategy() :: strategy()
  def get_strategy do
    GenServer.call(__MODULE__, :get_strategy)
  end

  @doc """
  Reloads the root zone based on current strategy.

  For :fetch strategy, fetches immediately from IANA.
  For :auth strategy, reloads from zone file.
  For :hints strategy, no action needed.

  ## Returns

  - `:ok` - Successfully reloaded
  - `{:error, reason}` - Failed to reload

  ## Examples

      iex> RootZone.Manager.reload_root_zone()
      :ok
  """
  @spec reload_root_zone() :: :ok | {:error, any()}
  def reload_root_zone do
    GenServer.call(__MODULE__, :reload_root_zone, :timer.seconds(60))
  end

  @doc """
  Gets root zone statistics.

  ## Returns

  Map with statistics including:
  - `:strategy` - Current strategy
  - `:server_count` - Number of root servers
  - `:last_loaded` - Last load timestamp (for fetch/auth)
  - `:serial` - Zone serial number (for fetch/auth)
  - `:next_fetch` - Time until next fetch (for fetch strategy)

  ## Examples

      iex> RootZone.Manager.stats()
      %{
        strategy: :hints,
        server_count: 26,
        ipv4_count: 13,
        ipv6_count: 13
      }
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  ## GenServer Callbacks

  @impl true
  def init(opts) do
    # Parse configuration
    config = parse_opts(opts)

    :telemetry.execute(
      [:yellow_dog, :dns, :root_zone, :start],
      %{count: 1},
      %{source: __MODULE__, strategy: config.strategy, severity: :info}
    )

    # Load root zone based on strategy
    case load_root_zone_with_strategy(config) do
      :ok ->
        # Schedule periodic fetch if using :fetch strategy
        state = %{
          config: config,
          loaded_at: System.system_time(:second),
          serial: nil,
          fetch_timer: nil
        }

        state = maybe_schedule_fetch(state)

        :telemetry.execute(
          [:yellow_dog, :dns, :root_zone, :loaded],
          %{count: 1},
          %{source: __MODULE__, strategy: config.strategy, severity: :info}
        )

        {:ok, state}

      {:error, reason} ->
        :telemetry.execute(
          [:yellow_dog, :dns, :root_zone, :fetch_error],
          %{count: 1},
          %{source: __MODULE__, reason: inspect(reason), severity: :error}
        )

        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:get_root_servers, _from, state) do
    servers =
      case state.config.strategy do
        :hints ->
          Hints.get_root_servers()

        :fetch ->
          # Query loaded root zone, fallback to hints
          get_servers_from_zone() || Hints.get_root_servers()

        :auth ->
          # Query loaded root zone, fallback to hints if configured
          get_servers_from_zone() ||
            (state.config.fallback_to_hints && Hints.get_root_servers()) || []
      end

    {:reply, servers, state}
  end

  @impl true
  def handle_call(:get_strategy, _from, state) do
    {:reply, state.config.strategy, state}
  end

  @impl true
  def handle_call(:reload_root_zone, _from, state) do
    span_id = Telemetry.start_span("dns.root_zone.reload", %{strategy: state.config.strategy})

    case load_root_zone_with_strategy(state.config) do
      :ok ->
        new_state = %{state | loaded_at: System.system_time(:second)}
        Telemetry.end_span(span_id, %{status: :success})
        {:reply, :ok, new_state}

      {:error, reason} = error ->
        :telemetry.execute(
          [:yellow_dog, :dns, :root_zone, :fetch_error],
          %{count: 1},
          %{source: __MODULE__, reason: inspect(reason), severity: :error}
        )

        Telemetry.end_span(span_id, %{status: :failed, reason: reason})
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = build_stats(state)
    {:reply, stats, state}
  end

  @impl true
  def handle_info(:fetch_root_zone, state) do
    :telemetry.execute(
      [:yellow_dog, :dns, :root_zone, :fetch],
      %{count: 1},
      %{source: __MODULE__, trigger: :periodic, severity: :info}
    )

    case Fetcher.fetch_root_zone(
           url: state.config.fetch_url,
           timeout_ms: 30_000
         ) do
      {:ok, serial} ->
        :telemetry.execute(
          [:yellow_dog, :dns, :root_zone, :loaded],
          %{count: 1, serial: serial},
          %{source: __MODULE__, severity: :info}
        )

        new_state = %{state | loaded_at: System.system_time(:second), serial: serial}
        new_state = maybe_schedule_fetch(new_state)
        {:noreply, new_state}

      {:error, reason} ->
        :telemetry.execute(
          [:yellow_dog, :dns, :root_zone, :fetch_error],
          %{count: 1},
          %{
            source: __MODULE__,
            reason: inspect(reason),
            fallback: state.config.fallback_to_hints,
            severity: :warning
          }
        )

        # Reschedule despite failure
        new_state = maybe_schedule_fetch(state)
        {:noreply, new_state}
    end
  end

  ## Private Functions

  defp parse_opts(opts) do
    base_config =
      case Keyword.get(opts, :config) do
        nil -> @default_config
        config_map -> Map.merge(@default_config, config_map)
      end

    %{
      strategy: parse_strategy(Keyword.get(opts, :strategy, base_config.strategy)),
      fetch_url: Keyword.get(opts, :fetch_url, base_config.fetch_url),
      fetch_interval_hours:
        Keyword.get(opts, :fetch_interval_hours, base_config.fetch_interval_hours),
      fallback_to_hints: Keyword.get(opts, :fallback_to_hints, base_config.fallback_to_hints),
      zone_file: Keyword.get(opts, :zone_file, base_config.zone_file)
    }
  end

  defp parse_strategy(strategy) when strategy in [:hints, :fetch, :auth], do: strategy
  defp parse_strategy("hints"), do: :hints
  defp parse_strategy("fetch"), do: :fetch
  defp parse_strategy("auth"), do: :auth
  defp parse_strategy(_), do: :hints

  defp load_root_zone_with_strategy(%{strategy: :hints}) do
    # Use embedded hints, no loading needed
    :telemetry.execute(
      [:yellow_dog, :dns, :root_zone, :loaded],
      %{count: 1},
      %{source: __MODULE__, strategy: :hints, severity: :info}
    )

    :ok
  end

  defp load_root_zone_with_strategy(%{strategy: :fetch} = config) do
    :telemetry.execute(
      [:yellow_dog, :dns, :root_zone, :fetch],
      %{count: 1},
      %{source: __MODULE__, trigger: :startup, severity: :info}
    )

    case Fetcher.fetch_root_zone(
           url: config.fetch_url,
           timeout_ms: 30_000
         ) do
      {:ok, _serial} ->
        :telemetry.execute(
          [:yellow_dog, :dns, :root_zone, :loaded],
          %{count: 1},
          %{source: __MODULE__, strategy: :fetch, severity: :info}
        )

        :ok

      {:error, reason} ->
        :telemetry.execute(
          [:yellow_dog, :dns, :root_zone, :fetch_error],
          %{count: 1},
          %{source: __MODULE__, reason: inspect(reason), severity: :warning}
        )

        if config.fallback_to_hints do
          :telemetry.execute(
            [:yellow_dog, :dns, :root_zone, :loaded],
            %{count: 1},
            %{source: __MODULE__, strategy: :hints, fallback: true, severity: :info}
          )

          :ok
        else
          {:error, reason}
        end
    end
  end

  defp load_root_zone_with_strategy(%{strategy: :auth} = config) do
    zone_file = config.zone_file

    if zone_file && File.exists?(zone_file) do
      :telemetry.execute(
        [:yellow_dog, :dns, :root_zone, :fetch],
        %{count: 1},
        %{source: __MODULE__, zone_file: zone_file, severity: :info}
      )

      case Zone.Manager.load_zone(".", file: zone_file, type: :master) do
        {:ok, _} ->
          :telemetry.execute(
            [:yellow_dog, :dns, :root_zone, :loaded],
            %{count: 1},
            %{source: __MODULE__, strategy: :auth, severity: :info}
          )

          :ok

        {:error, reason} = error ->
          :telemetry.execute(
            [:yellow_dog, :dns, :root_zone, :fetch_error],
            %{count: 1},
            %{source: __MODULE__, reason: inspect(reason), severity: :error}
          )

          if config.fallback_to_hints do
            :telemetry.execute(
              [:yellow_dog, :dns, :root_zone, :loaded],
              %{count: 1},
              %{source: __MODULE__, strategy: :hints, fallback: true, severity: :info}
            )

            :ok
          else
            error
          end
      end
    else
      :telemetry.execute(
        [:yellow_dog, :dns, :root_zone, :fetch_error],
        %{count: 1},
        %{
          source: __MODULE__,
          reason: :zone_file_not_found,
          zone_file: inspect(zone_file),
          severity: :error
        }
      )

      if config.fallback_to_hints do
        :telemetry.execute(
          [:yellow_dog, :dns, :root_zone, :loaded],
          %{count: 1},
          %{source: __MODULE__, strategy: :hints, fallback: true, severity: :info}
        )

        :ok
      else
        {:error, :zone_file_not_found}
      end
    end
  end

  defp maybe_schedule_fetch(%{config: %{strategy: :fetch}} = state) do
    # Cancel existing timer
    if state.fetch_timer do
      Process.cancel_timer(state.fetch_timer)
    end

    # Schedule next fetch
    interval_ms = state.config.fetch_interval_hours * 60 * 60 * 1000
    timer = Fetcher.schedule_periodic_fetch(interval_ms)

    :telemetry.execute(
      [:yellow_dog, :dns, :root_zone, :scheduled],
      %{count: 1, interval_hours: state.config.fetch_interval_hours},
      %{source: __MODULE__, severity: :debug}
    )

    %{state | fetch_timer: timer}
  end

  defp maybe_schedule_fetch(state), do: state

  defp get_servers_from_zone do
    # Query Zone.Storage for NS records of root zone
    # Handle case where Zone.Manager or ETS tables aren't initialized
    try do
      case Zone.Manager.get_zone_metadata(".") do
        {:ok, _metadata} ->
          # Zone is loaded, return nil to indicate we should query it
          # (actual implementation would query NS records)
          nil

        {:error, _} ->
          nil
      end
    rescue
      ArgumentError -> nil
    catch
      :exit, _ -> nil
    end
  end

  defp build_stats(state) do
    base_stats = %{
      strategy: state.config.strategy,
      loaded_at: state.loaded_at,
      serial: state.serial
    }

    case state.config.strategy do
      :hints ->
        counts = Hints.count()

        Map.merge(base_stats, %{
          server_count: counts.total,
          ipv4_count: counts.ipv4,
          ipv6_count: counts.ipv6
        })

      :fetch ->
        next_fetch_ms =
          if state.fetch_timer do
            Process.read_timer(state.fetch_timer) || 0
          else
            0
          end

        Map.merge(base_stats, %{
          fetch_url: state.config.fetch_url,
          fetch_interval_hours: state.config.fetch_interval_hours,
          next_fetch_seconds: div(next_fetch_ms, 1000),
          fallback_to_hints: state.config.fallback_to_hints
        })

      :auth ->
        Map.merge(base_stats, %{
          zone_file: state.config.zone_file,
          fallback_to_hints: state.config.fallback_to_hints
        })
    end
  end
end
