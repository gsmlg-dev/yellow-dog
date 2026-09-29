ExUnit.start()

alias YellowDog.Management.Repo
Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)
Ecto.Migrator.run(Repo, :up, all: true)
Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)
