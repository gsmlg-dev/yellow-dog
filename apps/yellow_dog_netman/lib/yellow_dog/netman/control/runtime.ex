defmodule YellowDog.Netman.Control.Runtime do
  @moduledoc false

  alias YellowDog.Netman.ReconciliationEngine
  alias YellowDog.Netman.RuntimeState
  alias YellowDog.Sync.Error

  @base_capabilities [
    "profiles.activate",
    "profiles.read",
    "profiles.rollback",
    "profiles.validate",
    "profiles.write",
    "runtime.apply_mode",
    "runtime.capabilities",
    "runtime.reconciliation_health"
  ]

  @feature_capabilities [
    {[:link_state], ["network.links.read"]},
    {[:interfaces], ["network.addresses.read"]},
    {[:routes], ["network.routes.read"]},
    {[:interfaces, :link_state], ["network.connections.read", "network.connections.write"]},
    {[:dns_client],
     [
       "resolved.cache.read",
       "resolved.cache.write",
       "resolved.config.rollback",
       "resolved.config.write",
       "resolved.counters.read",
       "resolved.link_dns.read",
       "resolved.queries.read",
       "resolved.search_domains.read",
       "resolved.upstreams.read"
     ]},
    {[:dhcp_client],
     ["dhcp_client.fsm.read", "dhcp_client.leases.read", "dhcp_client.leases.write"]},
    {[:vpn], ["vpn.profile.read"]}
  ]

  @spec dispatch(String.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def dispatch("netman.runtime.capabilities.get", _payload) do
    with {:ok, %{features: features}} <- RuntimeState.snapshot() do
      capabilities =
        Enum.reduce(@feature_capabilities, @base_capabilities, fn {required, capabilities}, acc ->
          if Enum.all?(required, &Map.get(features, &1, false)) do
            capabilities ++ acc
          else
            acc
          end
        end)

      {:ok, %{"capabilities" => Enum.sort(capabilities)}}
    else
      _error -> internal_error()
    end
  end

  def dispatch("netman.runtime.apply_mode.get", _payload) do
    with {:ok, %{apply_mode: mode}} <- RuntimeState.snapshot(),
         true <- mode in [:managed, :observe_first, :observe] do
      {:ok, %{"mode" => Atom.to_string(mode)}}
    else
      _error -> internal_error()
    end
  end

  def dispatch("netman.runtime.reconciliation_health.get", _payload) do
    with {:ok, %{apply_mode: mode}} <- RuntimeState.snapshot() do
      reconciliation_health(mode, ReconciliationEngine)
    else
      _error -> internal_error()
    end
  end

  def dispatch(_operation, _payload), do: unsupported_error()

  @doc false
  @spec reconciliation_health(:managed | :observe_first | :observe, module()) ::
          {:ok, map()}
  def reconciliation_health(mode, reconciliation_engine)
      when mode in [:managed, :observe_first, :observe] and is_atom(reconciliation_engine) do
    case safe_health(reconciliation_engine) do
      {:ok, %{status: status, pending_changes: pending_changes}}
      when status in [:healthy, :degraded, :unhealthy] and is_integer(pending_changes) and
             pending_changes >= 0 ->
        {:ok,
         %{
           "status" => Atom.to_string(status),
           "pending_changes" => pending_changes
         }}

      _error when mode in [:observe_first, :observe] ->
        {:ok, %{"status" => "healthy", "pending_changes" => 0}}

      _error ->
        {:ok, %{"status" => "unhealthy", "pending_changes" => 0}}
    end
  end

  defp safe_health(reconciliation_engine) do
    reconciliation_engine.health()
  rescue
    _exception -> {:error, :reconciliation_failed}
  catch
    _kind, _reason -> {:error, :reconciliation_failed}
  end

  defp unsupported_error,
    do: {:error, Error.new(:unsupported, "unsupported operation", %{})}

  defp internal_error, do: {:error, Error.new(:internal, "internal error", %{})}
end
