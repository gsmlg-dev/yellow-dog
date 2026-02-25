defmodule YellowDog.Resolved.Upstream do
  @moduledoc """
  Shared helpers for upstream DNS server address handling.

  Upstreams can be specified as bare IP tuples (port 53 assumed) or
  `{ip, port}` tuples. This module normalizes and formats both forms.
  """

  @typedoc "An upstream can be a bare IP (port 53 assumed) or {ip, port} tuple."
  @type t :: :inet.ip_address() | {:inet.ip_address(), :inet.port_number()}

  @doc "Normalize an upstream to `{ip, port}` tuple form."
  @spec normalize(t()) :: {:inet.ip_address(), :inet.port_number()}
  def normalize({ip, port}) when is_tuple(ip) and is_integer(port), do: {ip, port}
  def normalize(ip) when is_tuple(ip), do: {ip, 53}

  @doc "Format an upstream as a human-readable string."
  @spec format(t()) :: String.t()
  def format({ip, port}) when is_tuple(ip) and is_integer(port),
    do: "#{:inet.ntoa(ip)}:#{port}"

  def format(ip) when is_tuple(ip),
    do: to_string(:inet.ntoa(ip))
end
