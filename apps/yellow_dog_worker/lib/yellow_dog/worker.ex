defmodule YellowDog.Worker do
  @moduledoc "Local control. Every mutation uses the same complete WorkerPlan submission path."
  alias YellowDog.Worker.ServiceManager

  def reload(server \\ ServiceManager), do: ServiceManager.reload(server)
  def status(server \\ ServiceManager), do: ServiceManager.status(server)
  def check(server \\ ServiceManager), do: ServiceManager.check(server)

  @doc "Complete-plan attachment point shared by local reload and authenticated Management polling."
  def submit_plan(plan, server \\ ServiceManager), do: ServiceManager.submit_plan(server, plan)
end
