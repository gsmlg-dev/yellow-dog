defmodule YellowDog.Management.ExportScope do
  @moduledoc "Explicit limits of the current shared WorkerPlan export."

  @scope "dns_zones"
  @excluded ~w(dns_views geoip_artifacts)

  def scope, do: @scope
  def excluded, do: @excluded

  def description do
    "Exports contain DNS service settings and confirmed Zone assignments only. " <>
      "DNS Views and IP database artifacts are not serialized. Valid drafts can still be saved. " <>
      "Preparing or exporting a target does not deliver or load it on a Worker."
  end

  def validate(scope) when scope in [nil, @scope], do: :ok

  def validate("full") do
    {:error,
     %{
       code: "unsupported_export",
       message:
         "Full configuration export is unavailable because DNS Views and IP database artifacts " <>
           "are not serialized; valid drafts can still be saved.",
       details: %{"supported_scope" => @scope, "excluded" => @excluded}
     }}
  end

  def validate(_scope) do
    {:error,
     %{
       code: "invalid_request",
       message: "Export scope must be dns_zones or full",
       details: %{}
     }}
  end
end
