defmodule YellowDog.Server do
  @moduledoc """
  Start a GenServer to YellowDog DNS Server.

  uses directly the Erlang libraries
  - [gen_udp](https://www.erlang.org/doc/man/gen_udp.html)
  - [gen_tcp](https://www.erlang.org/doc/man/gen_tcp.html)

  """

  use Supervisor

  @spec start_link(YellowDog.ServerConfig.t()) :: Supervisor.on_start()
  def start_link(%YellowDog.ServerConfig{} = config) do
    Supervisor.start_link(__MODULE__, config, config.supervisor_options)
  end

  @impl Supervisor
  @spec init(YellowDog.ServerConfig.t()) ::
          {:ok,
           {Supervisor.sup_flags(),
            [Supervisor.child_spec() | (old_erlang_child_spec :: :supervisor.child_spec())]}}
  def init(config) do
    udp_config = YellowDog.ServerConfig.udp_config(config)

    children = [
      {Abyss, udp_config}
      |> Supervisor.child_spec(id: :udp_server),
      {YellowDog.ViewManager, []}
      |> Supervisor.child_spec(id: :view_manager)
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
