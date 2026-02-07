defmodule YellowDog.Console.ServiceHelper do
  @moduledoc """
  Safe service call wrapper for LiveView modules.

  Wraps calls to service modules (YellowDog.Dhcpv4, YellowDog.Dhcpv6, etc.)
  with Code.ensure_loaded? checks and try/rescue/catch error handling, returning
  a default value when the service is not available or crashes.
  """

  @doc """
  Safely calls a function, returning a default value if the module is not loaded
  or the call raises/exits.

  Accepts a zero-arity function that performs the service call. The module
  parameter is used for the Code.ensure_loaded? check.

  ## Examples

      safe_call(YellowDog.Dhcpv4, fn -> YellowDog.Dhcpv4.list_leases() end, [])
      safe_call(YellowDog.Dhcpv6, fn -> YellowDog.Dhcpv6.stats() end, default_stats())
  """
  def safe_call(module, fun, default \\ nil) do
    if Code.ensure_loaded?(module) do
      try do
        fun.()
      catch
        _, _ -> default
      end
    else
      default
    end
  end

  @doc """
  Checks whether a service process is registered and running.

  ## Examples

      service_running?(YellowDog.Dns)
      service_running?(YellowDog.Dhcpv4.LeaseManager)
  """
  def service_running?(process_name) do
    Process.whereis(process_name) != nil
  end
end
