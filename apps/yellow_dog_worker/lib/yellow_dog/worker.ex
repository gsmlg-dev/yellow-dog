defmodule YellowDog.Worker do
  @moduledoc "Local control. Every mutation uses the same complete WorkerPlan submission path."
  alias YellowDog.Worker.ServiceManager

  def reload(server \\ ServiceManager), do: ServiceManager.reload(server)
  def status(server \\ ServiceManager), do: ServiceManager.status(server)
  def check(server \\ ServiceManager), do: ServiceManager.check(server)

  @doc "Internal attachment point for a future authenticated Agent; no Agent runs in Phase 1."
  def submit_plan(plan, server \\ ServiceManager), do: ServiceManager.submit_plan(server, plan)
end
