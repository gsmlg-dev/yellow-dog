ExUnit.start()

defmodule YellowDogIdentity.TestHelper do
  @moduledoc false

  @doc """
  Stops the app-managed identity supervisor and registry so tests can start
  their own instances with `start_supervised!`.

  Call this in your test `setup` block before `start_supervised!`.
  """
  def stop_app_identity do
    # Wait briefly for async service startup to settle on first call
    unless Process.get(:identity_waited) do
      Process.sleep(100)
      Process.put(:identity_waited, true)
    end

    do_stop_app_identity(5)
  end

  defp do_stop_app_identity(0), do: :ok

  defp do_stop_app_identity(retries) do
    # Terminate and delete identity from the core supervisor to prevent restart
    try do
      if Process.whereis(YellowDog.Supervisor) do
        # child_spec id is YellowDogIdentity.Supervisor (from `use Supervisor`)
        Supervisor.terminate_child(YellowDog.Supervisor, YellowDogIdentity.Supervisor)
        Supervisor.delete_child(YellowDog.Supervisor, YellowDogIdentity.Supervisor)
      end
    catch
      :exit, _ -> :ok
    end

    # Stop the identity supervisor with a monitor to ensure it's fully dead
    stop_named_process(YellowDogIdentity.Supervisor)

    # Stop any orphaned registry process
    stop_named_process(YellowDogIdentity.Registry)

    # Check if anything came back (async startup task race)
    if Process.whereis(YellowDogIdentity.Supervisor) != nil ||
         Process.whereis(YellowDogIdentity.Registry) != nil do
      Process.sleep(50)
      do_stop_app_identity(retries - 1)
    else
      :ok
    end
  end

  defp stop_named_process(name) do
    case Process.whereis(name) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)

        try do
          GenServer.stop(pid, :normal, 1000)
        catch
          :exit, _ -> :ok
        end

        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          1000 -> Process.demonitor(ref, [:flush])
        end
    end
  end
end
