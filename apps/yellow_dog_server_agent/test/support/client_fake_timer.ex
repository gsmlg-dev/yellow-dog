defmodule YellowDog.ServerAgent.ClientFakeTimer do
  @moduledoc false

  def configure(owner) do
    :persistent_term.put({__MODULE__, :owner}, owner)
  end

  def clear do
    :persistent_term.erase({__MODULE__, :owner})
  end

  def send_after(destination, message, delay) do
    ref = make_ref()
    send(owner(), {:timer_scheduled, destination, message, delay, ref})
    ref
  end

  def cancel(ref) do
    send(owner(), {:timer_cancelled, ref})
    false
  end

  defp owner, do: :persistent_term.get({__MODULE__, :owner})
end
