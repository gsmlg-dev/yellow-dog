defmodule YellowDog.NetmanAgent.ClientFakeTimer do
  @moduledoc false

  def configure(owner), do: :persistent_term.put({__MODULE__, :owner}, owner)
  def clear, do: :persistent_term.erase({__MODULE__, :owner})

  def send_after(destination, message, delay) do
    ref = make_ref()

    send(
      :persistent_term.get({__MODULE__, :owner}),
      {:timer_scheduled, destination, message, delay, ref}
    )

    ref
  end

  def cancel(ref) do
    send(:persistent_term.get({__MODULE__, :owner}), {:timer_cancelled, ref})
    false
  end
end
