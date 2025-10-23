defmodule Abyss.ServerConfig do
  @moduledoc """
  Encapsulates the configuration of a Abyss server instance

  This is used internally by `Abyss.Handler`
  """

  @typedoc "A set of configuration parameters for a Abyss server instance"
  @type t :: %__MODULE__{
          port: :inet.port_number(),
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
          max_packet_size: pos_integer()
        }

  defstruct port: 4000,
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
            max_packet_size: 8192

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

    struct!(__MODULE__, opts)
  end

  @doc """
  Calculate optimal number of listeners based on current load and processing characteristics
  """
  @spec calculate_optimal_listeners(pos_integer(), float()) :: pos_integer()
  def calculate_optimal_listeners(current_connections, avg_processing_time_ms) do
    # Calculate based on current load and processing characteristics
    # Assume each listener can handle ~1000 concurrent connections efficiently
    base_listeners = div(current_connections, 1000)

    # Adjust for processing time (slower processing = more listeners needed)
    # Normalize to 100ms baseline
    processing_factor = max(avg_processing_time_ms / 100, 1)

    optimal = round(base_listeners * processing_factor)

    # Ensure at least 1 listener
    max(optimal, 1)
  end
end
