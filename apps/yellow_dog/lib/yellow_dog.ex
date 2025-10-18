defmodule YellowDog do
  @moduledoc """
  YellowDog is a distributed DNS and DHCP server.

  This is the core application that provides:
  - Configuration management
  - Orchestration of protocol-specific applications
  - Public API for the YellowDog system
  """

  @type options :: [
          handler_module: module(),
          handler_options: term(),
          port: :inet.port_number(),
          num_acceptors: pos_integer(),
          num_connections: non_neg_integer() | :infinity,
          max_connections_retry_count: non_neg_integer(),
          max_connections_retry_wait: timeout(),
          read_timeout: timeout(),
          shutdown_timeout: timeout(),
          silent_terminate_on_error: boolean()
        ]

  @banner_text "YellowDog DNS and DHCP Server"

  @doc false
  def banner do
    @banner_text
  end

  @doc """
  Returns a greeting.

  ## Examples

      iex> YellowDog.hello()
      :world

  """
  def hello do
    :world
  end

  @doc false
  @spec child_spec(options()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: {__MODULE__, make_ref()},
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      restart: :permanent
    }
  end

  @doc """
  Starts a `YellowDog` instance with the given options.
  """
  @spec start_link(options()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    opts
    |> YellowDog.ServerConfig.new()
    |> YellowDog.Server.start_link()
  end

  @doc """
  Get configuration value
  """
  def get_config(name) do
    YellowDog.Config.get(name)
  end

  @doc """
  Get all configuration
  """
  def get_all_config do
    YellowDog.Config.get_all()
  end
end
