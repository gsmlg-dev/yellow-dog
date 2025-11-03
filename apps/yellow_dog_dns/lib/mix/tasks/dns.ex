defmodule Mix.Tasks.Dns do
  @moduledoc """
  Mix tasks for DNS server management and operations.

  Usage:
      mix dns.status              # Show system status
      mix dns.health              # Run health check
      mix dns.metrics             # Display metrics
      mix dns.views               # List all views
      mix dns.view <name>         # Show view details
      mix dns.test <ip>           # Test which view matches an IP
      mix dns.reload              # Trigger configuration reload

  ## Examples

      # Check system health
      mix dns.health

      # List all configured views
      mix dns.views

      # Test which view matches a client IP
      mix dns.test 192.168.1.100

      # Trigger manual reload
      mix dns.reload
  """

  use Mix.Task
  @shortdoc "DNS server management tasks"

  def run(_args) do
    Mix.shell().info("""
    Available DNS tasks:

      mix dns.status              Show system status
      mix dns.health              Run health check
      mix dns.metrics             Display metrics
      mix dns.views               List all views
      mix dns.view <name>         Show view details
      mix dns.test <ip>           Test which view matches an IP
      mix dns.reload              Trigger configuration reload

    For help on a specific task, run: mix help <task>
    """)
  end
end

defmodule Mix.Tasks.Dns.Status do
  @moduledoc """
  Display DNS server status.

  Shows current status of ViewManager, ConfigWatcher, and overall system health.

  ## Usage

      mix dns.status
  """

  use Mix.Task
  @shortdoc "Display DNS server status"

  def run(_args) do
    Mix.Task.run("app.start")

    alias YellowDog.Dns.View.Operations

    case Operations.status() do
      {:ok, status} ->
        Mix.shell().info("\n=== DNS Server Status ===\n")

        # Manager status
        Mix.shell().info("ViewManager:")
        Mix.shell().info("  Views: #{status.manager.view_count}")
        Mix.shell().info("  Names: #{Enum.join(status.manager.view_names, ", ")}")
        Mix.shell().info("  Updates: #{status.manager.update_count}")

        if status.manager.last_update do
          Mix.shell().info("  Last Update: #{format_datetime(status.manager.last_update)}")
        end

        # Watcher status
        Mix.shell().info("\nConfigWatcher:")

        case status.watcher do
          %{status: :not_running} ->
            Mix.shell().info("  Status: Not Running (hot-reload disabled)")

          watcher_status ->
            Mix.shell().info("  Status: #{if watcher_status.watching, do: "Active", else: "Inactive"}")
            Mix.shell().info("  Config: #{watcher_status.config_path}")
            Mix.shell().info("  Reloads: #{watcher_status.reload_count}")
            Mix.shell().info("  Errors: #{watcher_status.error_count}")

            if watcher_status.last_reload do
              Mix.shell().info("  Last Reload: #{format_datetime(watcher_status.last_reload)}")
            end
        end

        # Overall health
        health_color =
          case status.health do
            :healthy -> :green
            :degraded -> :yellow
            :unhealthy -> :red
          end

        Mix.shell().info("\nOverall Health: #{colorize(to_string(status.health), health_color)}")

      {:error, reason} ->
        Mix.shell().error("Failed to get status: #{inspect(reason)}")
    end
  end

  defp format_datetime(dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")

  defp colorize(text, color) do
    case color do
      :green -> IO.ANSI.format([:green, text]) |> IO.iodata_to_binary()
      :yellow -> IO.ANSI.format([:yellow, text]) |> IO.iodata_to_binary()
      :red -> IO.ANSI.format([:red, text]) |> IO.iodata_to_binary()
      _ -> text
    end
  end
end

defmodule Mix.Tasks.Dns.Health do
  @moduledoc """
  Run comprehensive health check.

  Checks all components and reports overall system health.

  ## Usage

      mix dns.health
  """

  use Mix.Task
  @shortdoc "Run health check"

  def run(_args) do
    Mix.Task.run("app.start")

    alias YellowDog.Dns.View.Operations

    {:ok, health} = Operations.health_check()

    Mix.shell().info("\n=== DNS Health Check ===\n")

    # Overall status
    status_color =
      case health.status do
        :healthy -> :green
        :degraded -> :yellow
        :unhealthy -> :red
      end

    Mix.shell().info("Status: #{colorize(to_string(health.status), status_color)}\n")

    # Component checks
    Mix.shell().info("Component Checks:")

    Enum.each(health.checks, fn {component, status} ->
      {icon, color} =
        case status do
          :passing -> {"✓", :green}
          :warning -> {"⚠", :yellow}
          :failing -> {"✗", :red}
          :not_applicable -> {"-", :blue}
        end

      Mix.shell().info("  #{colorize(icon, color)} #{component}: #{status}")
    end)

    # Details
    if health.status != :healthy do
      Mix.shell().info("\nDetails:")

      Enum.each(health.details, fn {component, detail} ->
        if detail.status != :passing and detail.status != :not_applicable do
          Mix.shell().info("  #{component}: #{detail.message}")
        end
      end)
    end

    Mix.shell().info("")

    # Exit code based on health
    if health.status == :unhealthy do
      System.halt(1)
    end
  end

  defp colorize(text, color) do
    case color do
      :green -> IO.ANSI.format([:green, text]) |> IO.iodata_to_binary()
      :yellow -> IO.ANSI.format([:yellow, text]) |> IO.iodata_to_binary()
      :red -> IO.ANSI.format([:red, text]) |> IO.iodata_to_binary()
      :blue -> IO.ANSI.format([:blue, text]) |> IO.iodata_to_binary()
      _ -> text
    end
  end
end

defmodule Mix.Tasks.Dns.Metrics do
  @moduledoc """
  Display DNS server metrics.

  Shows aggregated metrics from all components.

  ## Usage

      mix dns.metrics
  """

  use Mix.Task
  @shortdoc "Display server metrics"

  def run(_args) do
    Mix.Task.run("app.start")

    alias YellowDog.Dns.View.Operations

    {:ok, metrics} = Operations.get_metrics()

    Mix.shell().info("\n=== DNS Server Metrics ===\n")

    # Views
    Mix.shell().info("Views:")
    Mix.shell().info("  Count: #{metrics.views.count}")
    Mix.shell().info("  Names: #{Enum.join(metrics.views.names, ", ")}")

    # Reloads
    Mix.shell().info("\nReloads:")
    Mix.shell().info("  Total: #{metrics.reloads.total}")
    Mix.shell().info("  Successful: #{metrics.reloads.successful}")
    Mix.shell().info("  Failed: #{metrics.reloads.failed}")

    if metrics.reloads.total > 0 do
      success_rate = Float.round(metrics.reloads.successful / metrics.reloads.total * 100, 2)
      Mix.shell().info("  Success Rate: #{success_rate}%")
    end

    if metrics.reloads.last_reload do
      Mix.shell().info("  Last Reload: #{format_datetime(metrics.reloads.last_reload)}")
    end

    # Operations
    Mix.shell().info("\nOperations:")
    Mix.shell().info("  Update Count: #{metrics.operations.update_count}")

    if metrics.operations.last_update do
      Mix.shell().info("  Last Update: #{format_datetime(metrics.operations.last_update)}")
    end

    Mix.shell().info("")
  end

  defp format_datetime(dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
end

defmodule Mix.Tasks.Dns.Views do
  @moduledoc """
  List all configured DNS views.

  Displays all views with their configuration details.

  ## Usage

      mix dns.views
  """

  use Mix.Task
  @shortdoc "List all views"

  def run(_args) do
    Mix.Task.run("app.start")

    alias YellowDog.Dns.View.Operations

    {:ok, views} = Operations.list_views()

    Mix.shell().info("\n=== DNS Views (#{length(views)}) ===\n")

    Enum.each(views, fn view ->
      Mix.shell().info("#{view.name}:")
      Mix.shell().info("  Match Clients: #{view.match_clients}")
      Mix.shell().info("  Zones: #{view.zone_count}")

      if view.zone_count > 0 do
        Mix.shell().info("    - #{Enum.join(view.zones, "\n    - ")}")
      end

      Mix.shell().info("  Recursion: #{if view.recursion_enabled, do: "Enabled", else: "Disabled"}")
      Mix.shell().info("")
    end)
  end
end

defmodule Mix.Tasks.Dns.View do
  @moduledoc """
  Show detailed information about a specific view.

  ## Usage

      mix dns.view <view_name>

  ## Examples

      mix dns.view internal
      mix dns.view external
  """

  use Mix.Task
  @shortdoc "Show view details"

  def run([view_name]) do
    Mix.Task.run("app.start")

    alias YellowDog.Dns.View.Operations

    case Operations.get_view_info(view_name) do
      {:ok, info} ->
        Mix.shell().info("\n=== View: #{info.name} ===\n")
        Mix.shell().info("Match Clients: #{info.match_clients}")
        Mix.shell().info("Zones: #{info.zone_count}")

        if info.zone_count > 0 do
          Mix.shell().info("  - #{Enum.join(info.zones, "\n  - ")}")
        end

        Mix.shell().info("\nRecursion: #{if info.recursion_enabled, do: "Enabled", else: "Disabled"}")

        Mix.shell().info("\nMatch Clients Details:")
        Mix.shell().info("  Type: #{info.match_clients_details.type}")
        Mix.shell().info("  Pattern: #{info.match_clients_details.pattern}")
        Mix.shell().info("")

      {:error, :view_not_found} ->
        Mix.shell().error("View '#{view_name}' not found")
    end
  end

  def run([]) do
    Mix.shell().error("Usage: mix dns.view <view_name>")
  end
end

defmodule Mix.Tasks.Dns.Test do
  @moduledoc """
  Test which view matches a client IP address.

  Useful for debugging and verifying view configuration.

  ## Usage

      mix dns.test <ip_address>

  ## Examples

      mix dns.test 192.168.1.100
      mix dns.test 10.0.0.1
      mix dns.test 8.8.8.8
  """

  use Mix.Task
  @shortdoc "Test client IP matching"

  def run([ip_string]) do
    Mix.Task.run("app.start")

    alias YellowDog.Dns.View.Operations

    case parse_ip(ip_string) do
      {:ok, ip} ->
        case Operations.test_client_match(ip) do
          {:ok, result} ->
            Mix.shell().info("\n=== Client Match Test ===\n")
            Mix.shell().info("Client IP: #{result.client_ip}")
            Mix.shell().info("Matched View: #{result.matched_view}")
            Mix.shell().info("Recursion: #{if result.recursion_enabled, do: "Enabled", else: "Disabled"}")
            Mix.shell().info("Accessible Zones: #{length(result.accessible_zones)}")

            if length(result.accessible_zones) > 0 do
              Mix.shell().info("  - #{Enum.join(result.accessible_zones, "\n  - ")}")
            end

            Mix.shell().info("")

          {:error, error} ->
            Mix.shell().error("No view matches IP #{error.client_ip}")
        end

      {:error, :invalid_ip} ->
        Mix.shell().error("Invalid IP address: #{ip_string}")
    end
  end

  def run([]) do
    Mix.shell().error("Usage: mix dns.test <ip_address>")
  end

  defp parse_ip(ip_string) do
    charlist = String.to_charlist(ip_string)

    case :inet.parse_ipv4_address(charlist) do
      {:ok, ip} ->
        {:ok, ip}

      {:error, _} ->
        case :inet.parse_ipv6_address(charlist) do
          {:ok, ip} -> {:ok, ip}
          {:error, _} -> {:error, :invalid_ip}
        end
    end
  end
end

defmodule Mix.Tasks.Dns.Reload do
  @moduledoc """
  Manually trigger a configuration reload.

  Forces an immediate reload of the views configuration file.

  ## Usage

      mix dns.reload
  """

  use Mix.Task
  @shortdoc "Trigger configuration reload"

  def run(_args) do
    Mix.Task.run("app.start")

    alias YellowDog.Dns.View.Operations

    Mix.shell().info("Triggering configuration reload...")

    case Operations.trigger_reload() do
      {:ok, result} ->
        Mix.shell().info("✓ Reload successful")
        Mix.shell().info("  Triggered at: #{format_datetime(result.triggered_at)}")

      {:error, :watcher_not_running} ->
        Mix.shell().error("✗ ConfigWatcher is not running")
        Mix.shell().error("  Hot-reload may be disabled")

      {:error, reason} ->
        Mix.shell().error("✗ Reload failed: #{inspect(reason)}")
    end
  end

  defp format_datetime(dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
end
