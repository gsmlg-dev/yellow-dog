defmodule YellowDog.Store.SingleNode do
  @moduledoc """
  Compatibility shim — delegates to `YellowDog.Store.ModeDetector` (mode
  detection) and `YellowDog.Store.Backend.Ets` (storage operations).

  New code should call `YellowDog.Store.ModeDetector` and
  `YellowDog.Store.Backend.Ets` directly. This module exists only so that
  existing call-sites and tests continue to work without modification.
  """

  alias YellowDog.Store.Backend.Ets, as: EtsBackend
  alias YellowDog.Store.ModeDetector

  @doc "Returns true when the Store is operating in single-node (ETS) mode."
  @spec single_node?() :: boolean()
  defdelegate single_node?(), to: ModeDetector

  @doc "Returns the current Store mode: :single_node or :cluster."
  @spec mode() :: :single_node | :cluster
  defdelegate mode(), to: ModeDetector

  @spec put(String.t(), term(), keyword()) :: :ok
  defdelegate put(key, value, opts \\ []), to: EtsBackend

  @spec get(String.t(), keyword()) :: {:ok, term()} | {:error, :not_found}
  defdelegate get(key, opts \\ []), to: EtsBackend

  @spec delete(String.t()) :: :ok
  defdelegate delete(key), to: EtsBackend

  @spec put_if(String.t(), term(), keyword()) :: :ok | {:error, :condition_failed}
  defdelegate put_if(key, value, opts \\ []), to: EtsBackend

  @spec prefix_scan(String.t(), keyword()) :: {:ok, [{String.t(), term()}]}
  defdelegate prefix_scan(prefix, opts \\ []), to: EtsBackend

  @spec put_many(list()) :: {:ok, map()}
  defdelegate put_many(operations), to: EtsBackend
end
