defmodule Abyss.Application do
  @moduledoc false
  # Minimal application whose only job is supervising Abyss.TableOwner, the
  # process that owns the shared ETS tables (listener info cache, telemetry
  # metrics). Without it, those named tables would be owned by whichever
  # server or listener process happened to create them first and would vanish
  # when that process died, breaking every other Abyss instance in the node.

  use Application

  @impl Application
  def start(_type, _args) do
    Supervisor.start_link([Abyss.TableOwner],
      strategy: :one_for_one,
      name: Abyss.Supervisor
    )
  end
end
