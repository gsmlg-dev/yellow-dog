defmodule YellowDog.Worker.Dns.Forwarder do
  @moduledoc false
  # Forward-only resolution: try each forwarder in order with RD=1; any error
  # (timeout, mismatch, malformed) moves on to the next. Never falls back to recursion.

  alias YellowDog.Worker.Dns.Upstream

  @spec resolve(
          [{:inet.ip_address(), :inet.port_number()}],
          String.t(),
          non_neg_integer(),
          keyword()
        ) ::
          {:ok, DNS.Message.t()} | {:error, :servfail}
  def resolve(servers, name, type, opts) do
    query_opts = [rd: true] ++ Keyword.take(opts, [:timeout])

    Enum.find_value(servers, {:error, :servfail}, fn server ->
      case Upstream.query(server, name, type, query_opts) do
        {:ok, message} -> {:ok, message}
        {:error, _} -> nil
      end
    end)
  end
end
