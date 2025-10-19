defmodule YellowDog.Application do
  @moduledoc """
  Main application supervisor for YellowDog with conditional service starting.

  Starts the configuration manager first, then conditionally starts protocol
  services based on the configuration settings.
  """

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    # Load configuration from application config or use defaults
    config = Application.get_env(:yellow_dog, :toml_config, %{})

    children = [
      # Configuration manager - must start first
      {YellowDog.Config, config}
    ]

    # Add protocol supervisors conditionally based on configuration
    children = children ++ get_enabled_services(config)

    opts = [strategy: :one_for_one, name: YellowDog.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Gets the list of enabled service supervisors based on configuration.
  defp get_enabled_services(config) do
    services = [
      {YellowDog.Dns, :dns},
      {YellowDog.Mdns, :mdns},
      {YellowDog.Dhcpv4, :dhcpv4},
      {YellowDog.Dhcpv6, :dhcpv6}
    ]

    # Filter services based on configuration
    enabled_services =
      services
      |> Enum.filter(fn {_module, service_name} ->
        is_service_enabled?(config, service_name)
      end)
      |> Enum.map(fn {module, _service_name} ->
        {module, []}
      end)

    # Log which services are being started
    service_names =
      services
      |> Enum.filter(fn {_module, service_name} ->
        is_service_enabled?(config, service_name)
      end)
      |> Enum.map(fn {_module, service_name} ->
        service_name |> to_string() |> String.upcase()
      end)

    if length(service_names) > 0 do
      Logger.info("Starting services: #{Enum.join(service_names, ", ")}")
    end

    # Log disabled services
    disabled_services =
      services
      |> Enum.filter(fn {_module, service_name} ->
        not is_service_enabled?(config, service_name)
      end)
      |> Enum.map(fn {_module, service_name} ->
        service_name |> to_string() |> String.upcase()
      end)

    if length(disabled_services) > 0 do
      Logger.info("Skipping disabled services: #{Enum.join(disabled_services, ", ")}")
    end

    enabled_services
  end

  # Checks if a service is enabled in the configuration.
  defp is_service_enabled?(config, service_name) do
    case Map.get(config, "core") do
      %{"dns" => dns, "mdns" => mdns, "dhcpv4" => dhcpv4, "dhcpv6" => dhcpv6} ->
        case service_name do
          :dns -> dns
          :mdns -> mdns
          :dhcpv4 -> dhcpv4
          :dhcpv6 -> dhcpv6
        end

      core_config when is_map(core_config) ->
        Map.get(core_config, to_string(service_name), true)

      _ ->
        # Default to enabled if no configuration is found
        true
    end
  end
end
