defmodule YellowDog.NetmanAgent.RollbackTimerTestClock do
  @state_key {__MODULE__, :now}

  def set(value) when is_integer(value), do: :persistent_term.put(@state_key, value)
  def clear, do: :persistent_term.erase(@state_key)
  def now, do: :persistent_term.get(@state_key)
end

defmodule YellowDog.NetmanAgent.RollbackTimerTestTimer do
  def configure(owner), do: :persistent_term.put({__MODULE__, :owner}, owner)
  def clear, do: :persistent_term.erase({__MODULE__, :owner})

  def send_after(destination, message, delay) do
    ref = make_ref()

    send(
      :persistent_term.get({__MODULE__, :owner}),
      {:rollback_timer_scheduled, destination, message, delay, ref}
    )

    ref
  end

  def cancel(ref) do
    send(:persistent_term.get({__MODULE__, :owner}), {:rollback_timer_cancelled, ref})
    false
  end
end
