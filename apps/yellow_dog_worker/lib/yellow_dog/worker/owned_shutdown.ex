defmodule YellowDog.Worker.OwnedShutdown do
  @moduledoc false

  def stop(pid, owned \\ [], timeout \\ 1000) do
    finish(pid, owned, fn -> graceful_stop(pid, timeout) end)
  end

  def terminate_task(pid) do
    finish(pid, [], fn ->
      Process.exit(pid, :shutdown)
      :ok
    end)
  end

  defp finish(pid, owned, shutdown) do
    monitors =
      [pid | owned]
      |> Enum.filter(&is_pid/1)
      |> Enum.flat_map(&tree/1)
      |> Enum.uniq()
      |> Enum.map(&{&1, Process.monitor(&1)})

    result = shutdown.()
    pending = await(monitors, deadline(1000))

    reply =
      if result == :ok and pending == [] do
        :ok
      else
        remaining = kill(pending, deadline(1000))
        {:error, {:shutdown_failed, result, Enum.map(remaining, &elem(&1, 0))}}
      end

    Enum.each(monitors, fn {_pid, monitor} -> Process.demonitor(monitor, [:flush]) end)
    reply
  end

  def tree(pid) do
    case Process.info(pid, :links) do
      {:links, links} ->
        children = Enum.filter(links, &owned_child?(&1, pid))
        [pid | Enum.flat_map(children, &tree/1)]

      nil ->
        [pid]
    end
  end

  defp owned_child?(child, parent) when is_pid(child) do
    case Process.info(child, :dictionary) do
      {:dictionary, dictionary} -> parent in Keyword.get(dictionary, :"$ancestors", [])
      nil -> false
    end
  end

  defp owned_child?(_child, _parent), do: false

  defp graceful_stop(pid, timeout) when is_pid(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal, timeout), else: :ok
  catch
    :exit, {:noproc, _} -> :ok
    :exit, reason -> {:error, reason}
  end

  defp graceful_stop(nil, _timeout), do: :ok

  defp await([], _deadline), do: []

  defp await([{pid, monitor} | rest] = monitors, deadline) do
    receive do
      {:DOWN, ^monitor, :process, ^pid, _reason} -> await(rest, deadline)
    after
      max(0, deadline - System.monotonic_time(:millisecond)) -> monitors
    end
  end

  defp kill([], _deadline), do: []

  defp kill([{pid, monitor} | rest] = monitors, deadline) do
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^monitor, :process, ^pid, _reason} -> kill(rest, deadline)
    after
      max(0, deadline - System.monotonic_time(:millisecond)) -> monitors
    end
  end

  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout
end
