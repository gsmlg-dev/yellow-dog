defmodule Abyss.ServerConfig do
  @moduledoc """
  Encapsulates the configuration of a Abyss server instance

  This is used internally by `Abyss.Handler`
  """

  @typedoc "A set of configuration parameters for a Abyss server instance"
  @type t :: %__MODULE__{
          port: :inet.port_number(),
          transport_module: module(),
          transport_options: Abyss.transport_options(),
          handler_module: module(),
          handler_options: term(),
          genserver_options: GenServer.options(),
          supervisor_options: [Supervisor.option()],
          broadcast: boolean(),
          num_listeners: pos_integer(),
          num_connections: non_neg_integer() | :infinity,
          max_connections_retry_count: non_neg_integer(),
          max_connections_retry_wait: timeout(),
          read_timeout: timeout(),
          shutdown_timeout: timeout(),
          udp_buffer_size: pos_integer(),
          dynamic_listeners: boolean(),
          min_listeners: pos_integer(),
          max_listeners: pos_integer(),
          listener_scale_threshold: float(),
          silent_terminate_on_error: boolean(),
          rate_limit_enabled: boolean(),
          rate_limit_max_packets: pos_integer(),
          rate_limit_window_ms: pos_integer(),
          max_packet_size: pos_integer(),
          connection_telemetry_sample_rate: float(),
          handler_memory_check_interval: pos_integer(),
          handler_memory_warning_threshold: pos_integer(),
          handler_memory_hard_limit: pos_integer()
        }

  defstruct port: 4000,
            transport_module: Abyss.Transport.UDP,
            transport_options: [],
            handler_module: nil,
            handler_options: [],
            genserver_options: [],
            supervisor_options: [],
            broadcast: false,
            num_listeners: 100,
            num_connections: 16_384,
            max_connections_retry_count: 5,
            max_connections_retry_wait: 1000,
            read_timeout: 60_000,
            shutdown_timeout: 15_000,
            udp_buffer_size: 64 * 1024,
            dynamic_listeners: false,
            min_listeners: 10,
            max_listeners: 1000,
            listener_scale_threshold: 0.8,
            silent_terminate_on_error: false,
            rate_limit_enabled: false,
            rate_limit_max_packets: 1000,
            rate_limit_window_ms: 1000,
            max_packet_size: 8192,
            connection_telemetry_sample_rate: 0.05,
            handler_memory_check_interval: 10_000,
            handler_memory_warning_threshold: 100,
            handler_memory_hard_limit: 150

  @spec new(Abyss.options()) :: t()
  def new(opts \\ []) do
    unless Keyword.keyword?(opts) do
      raise ArgumentError, "configuration must be a keyword list"
    end

    unless Keyword.has_key?(opts, :handler_module) do
      raise ArgumentError, "No handler_module defined in server configuration"
    end

    handler_module = Keyword.get(opts, :handler_module)

    unless is_atom(handler_module) do
      raise ArgumentError, "handler_module must be a module"
    end

    broadcast = get_in(opts, [:transport_options, :broadcast])

    opts =
      if broadcast == true do
        opts |> Keyword.put(:broadcast, true)
      else
        opts
      end

    config = struct!(__MODULE__, opts)

    # Validate numeric ranges for new configuration options
    validate_config!(config)

    config
  end

  # Private validation function
  defp validate_config!(config) do
    # Validate listener scaling configuration
    unless config.min_listeners > 0 and config.min_listeners <= config.max_listeners do
      raise ArgumentError,
            "min_listeners must be positive and <= max_listeners (got min: #{config.min_listeners}, max: #{config.max_listeners})"
    end

    unless config.listener_scale_threshold > 0.0 and config.listener_scale_threshold <= 1.0 do
      raise ArgumentError,
            "listener_scale_threshold must be between 0.0 and 1.0 (got #{config.listener_scale_threshold})"
    end

    # Validate telemetry sampling rate
    unless config.connection_telemetry_sample_rate >= 0.0 and
             config.connection_telemetry_sample_rate <= 1.0 do
      raise ArgumentError,
            "connection_telemetry_sample_rate must be between 0.0 and 1.0 (got #{config.connection_telemetry_sample_rate})"
    end

    # Validate memory thresholds
    unless config.handler_memory_check_interval > 0 do
      raise ArgumentError,
            "handler_memory_check_interval must be positive (got #{config.handler_memory_check_interval})"
    end

    unless config.handler_memory_warning_threshold > 0 and
             config.handler_memory_warning_threshold < config.handler_memory_hard_limit do
      raise ArgumentError,
            "handler_memory_warning_threshold must be positive and < handler_memory_hard_limit (got warning: #{config.handler_memory_warning_threshold}, hard limit: #{config.handler_memory_hard_limit})"
    end

    :ok
  end

  @doc """
  Calculate optimal number of listeners based on current load and processing characteristics

  Uses a more granular scaling approach:
  - 1 listener per 100 connections (instead of 1000)
  - Adjusts for processing time with a lower bound of 0.5x
  - Ensures minimum of 1 listener

  ## Examples

      iex> Abyss.ServerConfig.calculate_optimal_listeners(50, 100.0)
      1

      iex> Abyss.ServerConfig.calculate_optimal_listeners(500, 100.0)
      5

      iex> Abyss.ServerConfig.calculate_optimal_listeners(500, 200.0)
      10
  """
  @spec calculate_optimal_listeners(pos_integer(), float()) :: pos_integer()
  def calculate_optimal_listeners(current_connections, avg_processing_time_ms) do
    # Start with at least 1 listener per 100 connections
    # This provides better granularity for low to medium loads
    base_listeners = max(div(current_connections, 100), 1)

    # Adjust for processing time (slower processing = more listeners needed)
    # Normalize to 100ms baseline, with minimum factor of 0.5
    processing_factor = max(avg_processing_time_ms / 100, 0.5)

    optimal = round(base_listeners * processing_factor)

    # Ensure reasonable bounds
    max(optimal, 1)
  end
end
