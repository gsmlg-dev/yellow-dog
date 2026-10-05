defmodule YellowDog.Management.Application do
  use Application
  alias YellowDog.Management.{GeoIP, LogStream, MacDatabase, Repo, Settings}

  @impl true
  def start(_type, _args) do
    children = [
      Repo,
      {Phoenix.PubSub, name: YellowDog.ManagementUI.PubSub},
      LogStream,
      {GeoIP,
       paths: Settings.geoip_paths(),
       restore_selection:
         Application.get_env(:yellow_dog_management, :restore_geoip_selection, true)},
      {MacDatabase, path: Settings.mac_database_path()},
      {Oban, Application.fetch_env!(:yellow_dog_management, Oban)},
      {YellowDog.Management.TaskScheduler, []},
      {YellowDog.ManagementUI.Endpoint, Settings.endpoint()}
    ]

    children =
      if Application.get_env(:yellow_dog_management, :task_scheduler_enabled, true),
        do: children,
        else:
          Enum.reject(children, fn child ->
            match?({YellowDog.Management.TaskScheduler, _opts}, child)
          end)

    Supervisor.start_link(children, strategy: :one_for_one, name: YellowDog.Management.Supervisor)
  end

  @impl true
  def config_change(changed, _new, removed) do
    YellowDog.ManagementUI.Endpoint.config_change(changed, removed)
    :ok
  end
end
