defmodule YellowDog.Worker.Application do
  @moduledoc false
  use Application

  def start(_type, _args) do
    children =
      if Application.get_env(:yellow_dog_worker, :boot, true) do
        path = Application.get_env(:yellow_dog_worker, :bootstrap)

        case YellowDog.Worker.Bootstrap.load(path) do
          {:ok, options} ->
            services = [
              {YellowDog.Worker.ServiceManager,
               options
               |> Keyword.delete(:connection)
               |> Keyword.put(:name, YellowDog.Worker.ServiceManager)}
            ]

            case options[:connection] do
              nil ->
                services

              _connection ->
                services ++
                  [
                    {YellowDog.Worker.Connection,
                     [
                       bootstrap_path: path,
                       worker_id: options[:worker_id],
                       manager: YellowDog.Worker.ServiceManager
                     ]}
                  ]
            end

          {:error, reason} ->
            raise "Worker bootstrap failed: #{inspect(reason)}"
        end
      else
        []
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: YellowDog.Worker.Supervisor)
  end
end
