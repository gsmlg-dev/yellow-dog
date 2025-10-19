defmodule YellowDog.Dns do
  @moduledoc """
  DNS application that manages DNS functionality including name resolution, zones, and views.

  The DNS application provides a complete DNS server implementation with support for:
  - Standard DNS query types (A, AAAA, MX, NS, SOA, TXT, CNAME, etc.)
  - DNS views for different client perspectives
  - Zone management and ACL-based access control
  - Caching for improved performance
  - Integration with the YellowDog configuration system

  ## Architecture

  The DNS application consists of several key components:

  - **YellowDog.Dns.Server**: The main DNS server using Abyss UDP library
  - **YellowDog.Dns.Handler.UDP**: UDP packet handler for DNS queries
  - **YellowDog.Dns.ViewManager**: Manages DNS views and perspectives
  - **YellowDog.Dns.NameResolver**: Handles DNS name resolution logic
  - **YellowDog.Dns.View**: Core view functionality with ACL, cache, and zone management

  ## Usage

  The DNS application is typically started as part of the YellowDog umbrella
  application and can be configured through the centralized configuration system.

  ```elixir
  # Start the DNS application
  {:ok, _pid} = YellowDog.Dns.start_link([])

  # Or use it as a child in a supervisor
  children = [
    {YellowDog.Dns, server_options: [port: 53, listen: "0.0.0.0"]}
  ]
  ```

  ## Configuration

  The DNS server can be configured through the YellowDog configuration system:

  ```elixir
  # In your configuration
  config :dns,
    port: 53,
    listen: "0.0.0.0"
  ```
  """

  @doc """
  Starts the DNS server supervisor.

  Delegates to `YellowDog.Dns.Supervisor.start_link/1`.

  ## Options
  - `name`: Supervisor name (default: YellowDog.Dns)
  - `server_options`: Options passed to the DNS server

  ## Returns
  - `{:ok, pid}` - Supervisor started successfully
  - `{:error, reason}` - Failed to start supervisor
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  defdelegate start_link(options), to: YellowDog.Dns.Supervisor

  @doc """
  Returns a child specification for the DNS server supervisor.

  Delegates to `YellowDog.Dns.Supervisor.child_spec/1`.

  ## Returns
  - `Supervisor.child_spec()` - Child specification for the DNS supervisor
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  defdelegate child_spec(options), to: YellowDog.Dns.Supervisor

end
