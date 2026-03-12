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

  @wildcard_key "__wildcards__"

  @doc "Subscribe the current process to a topic."
  @spec subscribe(String.t()) :: {:ok, pid()} | {:error, term()}
  def subscribe(topic) when is_binary(topic) do
    result = Registry.register(@registry, topic, [])

    if String.ends_with?(topic, "*") do
      prefix = String.trim_trailing(topic, "*")
      Registry.register(@registry, @wildcard_key, prefix)
    end

    result
  end

  @doc "Unsubscribe the current process from a topic."
  @spec unsubscribe(String.t()) :: :ok
  def unsubscribe(topic) when is_binary(topic) do
    Registry.unregister(@registry, topic)

    if String.ends_with?(topic, "*") do
      prefix = String.trim_trailing(topic, "*")
      Registry.unregister_match(@registry, @wildcard_key, prefix)
    end
  end

  @doc """
  Publish a message to all subscribers of a topic.

  Also dispatches to wildcard subscribers. A subscription to `"netman:link:*"`
  will receive events published to any `"netman:link:<interface>"` topic.
  """
  @spec publish(String.t(), term()) :: :ok
  def publish(topic, message) when is_binary(topic) do
    # Dispatch to exact-match subscribers
    Registry.dispatch(@registry, topic, fn entries ->
      for {pid, _value} <- entries do
        send(pid, {:netman_event, topic, message})
      end
    end)

    # Dispatch to wildcard subscribers matching this topic
    dispatch_to_wildcards(topic, message)
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
    |> Enum.filter(fn {topic, _pid} ->
      topic != @wildcard_key and String.starts_with?(topic, prefix)
    end)
    |> Enum.each(fn {topic, pid} ->
      send(pid, {:netman_event, topic, message})
    end)

    # Also dispatch to wildcard subscribers matching this prefix
    Registry.dispatch(@registry, @wildcard_key, fn entries ->
      for {pid, wildcard_prefix} <- entries,
          String.starts_with?(wildcard_prefix, prefix) or
            String.starts_with?(prefix, wildcard_prefix) do
        send(pid, {:netman_event, prefix, message})
      end
    end)
  end

  # Dispatch to wildcard subscribers using the dedicated __wildcards__ key.
  # Each wildcard entry stores the prefix (e.g., "netman:link:" for "netman:link:*").
  # This is O(W) where W = wildcard subscribers, instead of O(N) for all subscriptions.
  defp dispatch_to_wildcards(topic, message) do
    Registry.dispatch(@registry, @wildcard_key, fn entries ->
      for {pid, prefix} <- entries, String.starts_with?(topic, prefix) do
        send(pid, {:netman_event, topic, message})
      end
    end)
  end
end
