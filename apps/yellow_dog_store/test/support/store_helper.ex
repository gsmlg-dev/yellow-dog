defmodule YellowDog.StoreHelper do
  @moduledoc """
  Test helper for Store integration tests.

  Sets up the ETS backend so Store facade modules can operate without
  Concord running. Call `setup_store/0` in your test setup block.
  """

  alias YellowDog.Store.Backend
  alias YellowDog.Store.Backend.Ets, as: EtsBackend

  @doc """
  Ensures the ETS backend is active and the table exists.
  Clears all data for test isolation.

  Usage in tests:

      setup do
        YellowDog.StoreHelper.setup_store()
        :ok
      end
  """
  @spec setup_store() :: :ok
  def setup_store do
    EtsBackend.create_table()
    Backend.set_active(EtsBackend)
    clear_store()
    :ok
  end

  @doc """
  Clears all entries from the Store ETS table.
  """
  @spec clear_store() :: :ok
  def clear_store do
    table = EtsBackend.table()

    case :ets.whereis(table) do
      :undefined -> :ok
      _ref -> :ets.delete_all_objects(table)
    end

    :ok
  end
end
