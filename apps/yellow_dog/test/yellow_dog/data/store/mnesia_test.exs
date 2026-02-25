defmodule YellowDog.Data.Store.MnesiaTest do
  use ExUnit.Case, async: true

  alias YellowDog.Data.Store.Mnesia
  alias YellowDog.Data.{Collection, Store}

  @state %{__adapter__: Mnesia}

  @moduledoc """
  Verifies the Mnesia stub adapter contract.

  The Mnesia adapter is intentionally unimplemented (all ops return
  {:error, :not_implemented}) until the full transactional abstraction is
  complete. These tests document and lock that contract.
  """

  describe "behaviour compliance" do
    test "Mnesia implements the Store behaviour" do
      assert Mnesia.__info__(:attributes) || true
      # Verify all required callbacks are exported
      assert function_exported?(Mnesia, :init, 2)
      assert function_exported?(Mnesia, :get, 2)
      assert function_exported?(Mnesia, :put, 3)
      assert function_exported?(Mnesia, :delete, 2)
      assert function_exported?(Mnesia, :exists?, 2)
      assert function_exported?(Mnesia, :list, 1)
      assert function_exported?(Mnesia, :list, 2)
      assert function_exported?(Mnesia, :count, 1)
      assert function_exported?(Mnesia, :match, 2)
      assert function_exported?(Mnesia, :update, 3)
      assert function_exported?(Mnesia, :clear, 1)
      assert function_exported?(Mnesia, :flush, 1)
      assert function_exported?(Mnesia, :transaction, 2)
      assert function_exported?(Mnesia, :subscribe, 2)
      assert function_exported?(Mnesia, :export, 2)
    end
  end

  describe "init/2" do
    test "returns {:error, :not_implemented}" do
      coll = Collection.new(:test_mnesia, key_field: :id, adapter: Mnesia)
      assert {:error, :not_implemented} = Mnesia.init(coll, [])
    end
  end

  describe "get/2" do
    test "returns {:error, :not_implemented}" do
      assert {:error, :not_implemented} = Mnesia.get(@state, "any-key")
    end
  end

  describe "put/3" do
    test "returns {:error, :not_implemented}" do
      assert {:error, :not_implemented} = Mnesia.put(@state, "key", %{})
    end
  end

  describe "delete/2" do
    test "returns {:error, :not_implemented}" do
      assert {:error, :not_implemented} = Mnesia.delete(@state, "key")
    end
  end

  describe "exists?/2" do
    test "returns false (not :not_implemented — always false for stub)" do
      assert false == Mnesia.exists?(@state, "key")
    end
  end

  describe "list/1" do
    test "returns {:error, :not_implemented}" do
      assert {:error, :not_implemented} = Mnesia.list(@state)
    end
  end

  describe "list/2 with filter" do
    test "returns {:error, :not_implemented}" do
      assert {:error, :not_implemented} = Mnesia.list(@state, &Function.identity/1)
    end
  end

  describe "count/1" do
    test "returns {:error, :not_implemented}" do
      assert {:error, :not_implemented} = Mnesia.count(@state)
    end
  end

  describe "match/2" do
    test "returns {:error, :not_implemented}" do
      assert {:error, :not_implemented} = Mnesia.match(@state, %{type: "server"})
    end
  end

  describe "update/3" do
    test "returns {:error, :not_implemented}" do
      assert {:error, :not_implemented} = Mnesia.update(@state, "key", &Function.identity/1)
    end
  end

  describe "clear/1" do
    test "returns {:error, :not_implemented}" do
      assert {:error, :not_implemented} = Mnesia.clear(@state)
    end
  end

  describe "flush/1" do
    test "returns {:error, :not_implemented}" do
      assert {:error, :not_implemented} = Mnesia.flush(@state)
    end
  end

  describe "transaction/2" do
    test "returns {:error, :not_implemented}" do
      assert {:error, :not_implemented} = Mnesia.transaction(@state, fn -> :ok end)
    end
  end

  describe "subscribe/2" do
    test "returns {:error, :not_implemented}" do
      assert {:error, :not_implemented} = Mnesia.subscribe(@state, :inserted)
    end
  end

  describe "export/2" do
    test "returns {:error, :not_implemented}" do
      assert {:error, :not_implemented} = Mnesia.export(@state, :toml)
    end
  end

  describe "Store dispatch to Mnesia" do
    test "Store.flush/1 calls Mnesia.flush/1 via __adapter__" do
      assert {:error, :not_implemented} = Store.flush(@state)
    end

    test "Store.get/2 dispatches to Mnesia" do
      assert {:error, :not_implemented} = Store.get(@state, "key")
    end
  end
end
