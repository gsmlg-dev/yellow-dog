defmodule YellowDog do
  @moduledoc """
  Documentation for `YellowDog`.
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

  @banner_text File.read!("#{:code.priv_dir(:yellow_dog)}/banner.txt")

  @doc false
  def banner do
    @banner_text
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
  Starts a `YellowDog` instance with the given options. Returns a pid
  that can be used to further manipulate the server via other functions defined on
  this module in the case of success, or an error tuple describing the reason the
  server was unable to start in the case of failure.
  """
  @spec start_link(options()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    opts
    |> YellowDog.ServerConfig.new()
    |> YellowDog.Server.start_link()
  end
end
