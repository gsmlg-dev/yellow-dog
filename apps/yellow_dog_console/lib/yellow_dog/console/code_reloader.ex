defmodule YellowDog.Console.CodeReloader do
  @moduledoc false

  @spec reload(module(), keyword()) :: :ok | {:error, binary()}
  def reload(endpoint, opts) do
    reload(endpoint, opts, Phoenix.CodeReloader.Server)
  end

  @spec reload(module(), keyword(), atom()) :: :ok | {:error, binary()}
  def reload(endpoint, opts, server) do
    if Process.whereis(server) do
      Phoenix.CodeReloader.reload(endpoint, opts)
    else
      :ok
    end
  catch
    :exit, {:noproc, _} -> :ok
  end
end
