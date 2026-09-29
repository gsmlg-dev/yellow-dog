defmodule YellowDog.Worker.Application do
  @moduledoc false
  use Application

  def start(_type, _args) do
    children =
      if Application.get_env(:yellow_dog_worker, :boot, true) do
        path = Application.get_env(:yellow_dog_worker, :bootstrap)

        case YellowDog.Worker.Bootstrap.load(path) do
          {:ok, options} ->
            [
              {YellowDog.Worker.ServiceManager,
               Keyword.put(options, :name, YellowDog.Worker.ServiceManager)}
            ]

          {:error, reason} ->
            raise "Worker bootstrap failed: #{inspect(reason)}"
        end
      else
        []
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: YellowDog.Worker.Supervisor)
  end
end
