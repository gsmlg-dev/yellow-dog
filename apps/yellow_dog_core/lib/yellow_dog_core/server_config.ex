defmodule YellowDogCore.ServerConfig do
  @moduledoc """
  Documentation for `YellowDogCore.ServerConfig`.
  """

  @type t :: %__MODULE__{
          handler_module: module(),
          handler_options: term(),
          port: :inet.port_number(),
          num_acceptors: pos_integer(),
          num_connections: non_neg_integer() | :infinity,
          supervisor_options: [Supervisor.option()]
        }

  defstruct handler_module: nil,
            handler_options: nil,
            port: 53,
            num_acceptors: 100,
            num_connections: 1000,
            supervisor_options: [strategy: :one_for_one]

  def new(opts) do
    struct!(__MODULE__, opts)
  end

  def udp_config(config = %YellowDogCore.ServerConfig{}) do
    [
      port: config.port,
      transport_options: [debug: true],
      handler_module: YellowDogDns.Handler.UDP,
      handler_options: [],
      genserver_options: [],
      supervisor_options: [],
      num_listeners: 100,
      num_connections: 16_384,
      max_connections_retry_count: 5,
      max_connections_retry_wait: 1000,
      read_timeout: 30_000,
      shutdown_timeout: 15_000,
      silent_terminate_on_error: false
    ]
  end
end
