defmodule YellowDog.Netman.Application do
  @moduledoc false
  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    if netman_autostart?() and netman_supported?() do
      children = [
        {YellowDog.Resolved.Supervisor, []},
        {YellowDog.Netman.Supervisor, []}
      ]

      opts = [strategy: :one_for_one, name: YellowDog.Netman.AppSupervisor]
      Supervisor.start_link(children, opts)
    else
      if not netman_autostart?() do
        Logger.info(
          "[Netman] Skipping start — autostart is disabled. Use `mix netman.server` to start Netman."
        )
      else
        Logger.info(
          "[Netman] Skipping start — not supported on this platform (#{inspect(:os.type())})"
        )
      end

      Supervisor.start_link([], strategy: :one_for_one, name: YellowDog.Netman.AppSupervisor)
    end
  end

  # Returns false when :netman_autostart is explicitly set to false.
  # Used to prevent Netman from starting automatically when running `mix phx.server`.
  # The `mix netman.server` task sets this to true at runtime before starting.
  defp netman_autostart? do
    Application.get_env(:yellow_dog_netman, :netman_autostart, true) != false
  end

  # Netman requires Linux netlink interfaces. It is not supported on macOS/Darwin
  # or when explicitly disabled via the :netman_enabled application env.
  defp netman_supported? do
    Application.get_env(:yellow_dog, :netman_enabled, true) != false and
      :os.type() != {:unix, :darwin}
  end
end
