defmodule YellowDog.Data.RegistryTest do
  use ExUnit.Case, async: true

  alias YellowDog.Data.Registry
  alias YellowDog.Data.{Collection, Store}

  # Start an isolated Registry instance for each test (unique name avoids conflicts).
  setup do
    name = :"registry_test_#{:erlang.unique_integer([:positive])}"
    {:ok, pid} = GenServer.start_link(Registry, [], name: name)
    %{registry: name, pid: pid}
  end

  # A minimal real adapter_state for flush_all testing.
  # We use an ETS store initialized with a transient collection.
  defp build_ets_state do
    coll = Collection.new(:reg_test_tmp, key_field: :id, adapter: YellowDog.Data.Store.Ets)
    {:ok, state} = Store.Ets.init(coll, [])
    state
  end

  describe "register/3 and lookup/2" do
    test "returns :ok after register", %{registry: r} do
      assert :ok = Registry.register(:my_coll, %{dummy: true}, r)
    end

    test "lookup returns {:ok, state} after register", %{registry: r} do
      state = %{dummy: 42}
      Registry.register(:lookup_coll, state, r)
      assert {:ok, ^state} = Registry.lookup(:lookup_coll, r)
    end

    test "lookup returns {:error, :not_found} for unknown name", %{registry: r} do
      assert {:error, :not_found} = Registry.lookup(:nonexistent, r)
    end

    test "re-registering same name overwrites the state", %{registry: r} do
      Registry.register(:coll, %{v: 1}, r)
      Registry.register(:coll, %{v: 2}, r)
      assert {:ok, %{v: 2}} = Registry.lookup(:coll, r)
    end
  end

  describe "unregister/2" do
    test "unregister returns :ok", %{registry: r} do
      Registry.register(:to_remove, %{}, r)
      assert :ok = Registry.unregister(:to_remove, r)
    end

    test "after unregister, lookup returns :not_found", %{registry: r} do
      Registry.register(:gone, %{x: 1}, r)
      Registry.unregister(:gone, r)
      assert {:error, :not_found} = Registry.lookup(:gone, r)
    end

    test "unregistering non-existent name returns :ok", %{registry: r} do
      assert :ok = Registry.unregister(:never_registered, r)
    end
  end

  describe "list_collections/1" do
    test "returns empty list when nothing registered", %{registry: r} do
      assert [] = Registry.list_collections(r)
    end

    test "returns registered collection names", %{registry: r} do
      Registry.register(:alpha, %{}, r)
      Registry.register(:beta, %{}, r)
      names = Registry.list_collections(r)
      assert :alpha in names
      assert :beta in names
      assert length(names) == 2
    end

    test "does not include unregistered names", %{registry: r} do
      Registry.register(:keep, %{}, r)
      Registry.register(:remove, %{}, r)
      Registry.unregister(:remove, r)
      names = Registry.list_collections(r)
      assert :keep in names
      refute :remove in names
    end
  end

  describe "flush_all/1" do
    test "returns :ok with no collections", %{registry: r} do
      assert :ok = Registry.flush_all(r)
    end

    test "returns :ok with real ETS adapter state registered", %{registry: r} do
      state = build_ets_state()
      Registry.register(:ets_coll, state, r)
      assert :ok = Registry.flush_all(r)
    end

    test "flush_all leaves collections still registered", %{registry: r} do
      state = build_ets_state()
      Registry.register(:kept, state, r)
      Registry.flush_all(r)
      assert {:ok, _} = Registry.lookup(:kept, r)
    end
  end

  describe "isolation" do
    test "two registry instances are independent", %{registry: r} do
      name2 = :"registry_iso_#{:erlang.unique_integer([:positive])}"
      {:ok, _} = GenServer.start_link(Registry, [], name: name2)

      Registry.register(:shared_name, %{v: 1}, r)
      assert {:error, :not_found} = Registry.lookup(:shared_name, name2)
    end
  end
end
