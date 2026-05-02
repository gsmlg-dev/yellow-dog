defmodule YellowDog.Netman.Application do
  @moduledoc false
  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    if netman_supported?() do
      children = [
        {YellowDog.Resolved.Supervisor, []},
        {YellowDog.Netman.Supervisor, []}
      ]

      opts = [strategy: :one_for_one, name: YellowDog.Netman.AppSupervisor]
      Supervisor.start_link(children, opts)
    else
      Logger.info(
        "[Netman] Skipping start — not supported on this platform (#{inspect(:os.type())})"
      )

      Supervisor.start_link([], strategy: :one_for_one, name: YellowDog.Netman.AppSupervisor)
    end
  end

  # Netman requires Linux netlink interfaces. It is not supported on macOS/Darwin
  # or when explicitly disabled via the :netman_enabled application env.
  defp netman_supported? do
    Application.get_env(:yellow_dog, :netman_enabled, true) != false and
      :os.type() != {:unix, :darwin}
  end
end
