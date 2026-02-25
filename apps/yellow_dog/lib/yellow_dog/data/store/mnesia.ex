defmodule YellowDog.Data.Store.Mnesia do
  @moduledoc """
  Mnesia storage adapter (stub).

  Defines the adapter interface for Mnesia-backed collections. Currently
  unimplemented — DHCP lease stores use direct Mnesia calls. This module
  exists to declare the adapter and enable future migration once the
  transactional semantics are fully abstracted.

  ## Planned features

  - Disc-copies / ram-copies per collection
  - Secondary index creation from `Collection.indexes`
  - Transaction wrapping for `put`, `delete`, `update`, `clear`
  - Record ↔ map conversion using `Collection.schema`
  """

  @behaviour YellowDog.Data.Store

  @impl true
  def init(_collection, _opts), do: {:error, :not_implemented}

  @impl true
  def get(_state, _key), do: {:error, :not_implemented}

  @impl true
  def put(_state, _key, _record), do: {:error, :not_implemented}

  @impl true
  def delete(_state, _key), do: {:error, :not_implemented}

  @impl true
  def exists?(_state, _key), do: false

  @impl true
  def list(_state), do: {:error, :not_implemented}

  @impl true
  def list(_state, _filter_fn), do: {:error, :not_implemented}

  @impl true
  def count(_state), do: {:error, :not_implemented}

  @impl true
  def match(_state, _pattern), do: {:error, :not_implemented}

  @impl true
  def update(_state, _key, _update_fn), do: {:error, :not_implemented}

  @impl true
  def clear(_state), do: {:error, :not_implemented}

  @impl true
  def flush(_state), do: {:error, :not_implemented}

  @impl true
  def transaction(_state, _fun), do: {:error, :not_implemented}

  @impl true
  def subscribe(_state, _event), do: {:error, :not_implemented}

  @impl true
  def export(_state, _format), do: {:error, :not_implemented}
end
