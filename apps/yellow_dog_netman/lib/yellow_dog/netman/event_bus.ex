defmodule YellowDog.Netman.EventBus do
  @moduledoc """
  Registry-based PubSub for internal NetMan communication.

  Topics follow the pattern `netman:<subsystem>:<detail>`:

      netman:link:<interface>          # Link state changes
      netman:address:<interface>       # Address changes
      netman:route:<table>             # Route changes
      netman:connection:<id>           # Connection FSM state changes
      netman:policy:*                  # Policy decisions
      netman:profile:*                 # Profile CRUD events
      netman:reconciliation:*          # Reconciliation cycle events
  """

  @registry __MODULE__.Registry

  def child_spec(_opts) do
    Registry.child_spec(keys: :duplicate, name: @registry)
  end

  @doc "Subscribe the current process to a topic."
  @spec subscribe(String.t()) :: {:ok, pid()} | {:error, term()}
  def subscribe(topic) when is_binary(topic) do
    Registry.register(@registry, topic, [])
  end

  @doc "Unsubscribe the current process from a topic."
  @spec unsubscribe(String.t()) :: :ok
  def unsubscribe(topic) when is_binary(topic) do
    Registry.unregister(@registry, topic)
  end

  @doc "Publish a message to all subscribers of a topic."
  @spec publish(String.t(), term()) :: :ok
  def publish(topic, message) when is_binary(topic) do
    Registry.dispatch(@registry, topic, fn entries ->
      for {pid, _value} <- entries do
        send(pid, {:netman_event, topic, message})
      end
    end)
  end

  @doc """
  Broadcast to all subscribers whose topic matches a prefix.

  For example, `broadcast("netman:link:", message)` sends to all
  `netman:link:*` subscribers.
  """
  @spec broadcast(String.t(), term()) :: :ok
  def broadcast(prefix, message) when is_binary(prefix) do
    # Get all registered keys and match prefix
    Registry.select(@registry, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.filter(fn {topic, _pid} -> String.starts_with?(topic, prefix) end)
    |> Enum.each(fn {topic, pid} ->
      send(pid, {:netman_event, topic, message})
    end)
  end
end
