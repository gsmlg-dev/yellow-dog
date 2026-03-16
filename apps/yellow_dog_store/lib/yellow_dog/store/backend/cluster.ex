defmodule YellowDog.Store.Backend.Cluster do
  @moduledoc """
  Concord-backed storage backend for multi-node cluster deployments.

  Thin wrapper around the `Concord` API, implementing the `YellowDog.Store.Backend`
  behaviour. All Concord-specific calls in the Store codebase are isolated here.
  """

  @behaviour YellowDog.Store.Backend

  @impl true
  def put(key, value, opts), do: Concord.put(key, value, opts)

  @impl true
  def get(key, opts), do: Concord.get(key, opts)

  @impl true
  def delete(key), do: Concord.delete(key)

  @impl true
  def put_if(key, value, opts), do: Concord.put_if(key, value, opts)

  @impl true
  def prefix_scan(prefix, opts), do: Concord.prefix_scan(prefix, opts)

  @impl true
  def put_many(operations), do: Concord.put_many(operations)
end
