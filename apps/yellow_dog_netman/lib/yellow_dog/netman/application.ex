defmodule YellowDog.Netman.Application do
  @moduledoc false
  use Application

  alias YellowDog.Config.Schema
  alias YellowDog.ConfigHelpers
  alias YellowDog.Netman.ProfileResolver

  require Logger

  @impl true
  def start(_type, _args) do
    if netman_autostart?() and netman_supported?() do
      profile = load_config() |> ProfileResolver.resolve()
      children = netman_children(profile)

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

  @doc false
  def child_specs_for_profile(profile), do: netman_children(profile)

  # Returns false when :netman_autostart is explicitly set to false.
  # Used to prevent Netman from starting automatically when running `mix phx.server`.
  # The `mix netman.server` task sets this to true at runtime before starting.
  defp netman_autostart? do
    Application.get_env(:yellow_dog_netman, :netman_autostart, true) != false
  end

  defp netman_children(profile) do
    features = Map.get(profile, :features, %{})

    [{YellowDog.Netman.RuntimeState, netman_opts(profile)}]
    |> maybe_add_child(Map.get(features, :dns_client, false), {YellowDog.Resolved.Supervisor, []})
    |> maybe_add_child(
      start_netman_supervisor?(features),
      {YellowDog.Netman.Supervisor, netman_opts(profile)}
    )
    |> maybe_add_child(management_agent_enabled?(profile), netman_agent_child(profile))
    |> Enum.reject(&is_nil/1)
  end

  defp maybe_add_child(children, true, child), do: children ++ [child]
  defp maybe_add_child(children, _enabled, _child), do: children

  defp start_netman_supervisor?(features) do
    Enum.any?(
      [:interfaces, :dhcp_client, :dns_client, :routes, :link_state],
      &Map.get(features, &1, false)
    )
  end

  defp netman_opts(profile) do
    [
      features: Map.get(profile, :features, %{}),
      apply_mode: Map.get(profile, :apply_mode, :managed)
    ]
  end

  defp management_agent_enabled?(profile) do
    management = Map.get(profile, :management, %{})

    if not is_map(management) do
      true
    else
      agent_enabled =
        management
        |> ConfigHelpers.get_value(
          :agent_enabled,
          ConfigHelpers.get_value(management, :enabled, true)
        )

      agent_enabled != false
    end
  end

  defp netman_agent_child(profile) do
    module = YellowDog.NetmanAgent

    if Code.ensure_loaded?(module) do
      {module, [agent_id: Map.get(profile, :id) || "netman-local"]}
    end
  end

  defp load_config do
    cond do
      Process.whereis(YellowDog.Config) ->
        YellowDog.Config.get_all()

      config_file_path = Application.get_env(:yellow_dog, :config_file_path) ->
        load_config_file(config_file_path)

      true ->
        Schema.defaults()
    end
  end

  defp load_config_file(config_file_path) do
    with {:ok, content} <- File.read(config_file_path),
         {:ok, parsed} <- Toml.decode(content) do
      Schema.merge_defaults(parsed)
    else
      _error -> Schema.defaults()
    end
  end

  # Netman requires Linux netlink interfaces. It is not supported on macOS/Darwin
  # or when explicitly disabled via the :netman_enabled application env.
  defp netman_supported? do
    Application.get_env(:yellow_dog, :netman_enabled, true) != false and
      :os.type() != {:unix, :darwin}
  end
end
