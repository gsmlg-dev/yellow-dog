defmodule YellowDog.Data.CollectionTest do
  use ExUnit.Case, async: true

  alias YellowDog.Data.Collection
  alias YellowDog.Data.Store.Ets

  describe "Collection.new/2" do
    test "creates collection with required fields" do
      coll = Collection.new(:my_things, key_field: :id, adapter: Ets)
      assert coll.name == :my_things
      assert coll.key_field == :id
      assert coll.adapter == Ets
    end

    test "defaults key_field to :id" do
      coll = Collection.new(:my_things, adapter: Ets)
      assert coll.key_field == :id
    end

    test "defaults adapter to Store.Ets" do
      coll = Collection.new(:my_things, key_field: :name)
      assert coll.adapter == YellowDog.Data.Store.Ets
    end

    test "defaults indexes to empty list" do
      coll = Collection.new(:my_things, key_field: :id, adapter: Ets)
      assert coll.indexes == []
    end

    test "accepts custom indexes" do
      coll = Collection.new(:my_things, key_field: :id, adapter: Ets, indexes: [:name, :status])
      assert coll.indexes == [:name, :status]
    end

    test "persistence is nil by default" do
      coll = Collection.new(:my_things, key_field: :id, adapter: Ets)
      assert coll.persistence == nil
    end

    test "builds persistence from keyword opts" do
      coll =
        Collection.new(:my_things,
          key_field: :id,
          adapter: Ets,
          persistence: [strategy: :toml, path: "data/things.toml"]
        )

      assert coll.persistence == %{strategy: :toml, path: "data/things.toml", interval: 0}
    end

    test "persistence keyword defaults strategy to :toml" do
      coll =
        Collection.new(:my_things,
          key_field: :id,
          adapter: Ets,
          persistence: [path: "data/things.toml"]
        )

      assert coll.persistence.strategy == :toml
    end

    test "persistence keyword defaults interval to 0" do
      coll =
        Collection.new(:my_things,
          key_field: :id,
          adapter: Ets,
          persistence: [strategy: :json, path: "data/things.json"]
        )

      assert coll.persistence.interval == 0
    end

    test "builds persistence from a pre-built map" do
      persistence_map = %{strategy: :json, path: "data/x.json", interval: 60}

      coll =
        Collection.new(:my_things, key_field: :id, adapter: Ets, persistence: persistence_map)

      assert coll.persistence == persistence_map
    end

    test "schema defaults to nil" do
      coll = Collection.new(:my_things, key_field: :id, adapter: Ets)
      assert coll.schema == nil
    end

    test "accepts custom schema module" do
      coll = Collection.new(:my_things, key_field: :id, adapter: Ets, schema: MySchema)
      assert coll.schema == MySchema
    end
  end

  describe "defcollection macro" do
    defmodule TestModule do
      use YellowDog.Data.Collection

      defcollection(:test_items,
        key_field: :name,
        adapter: YellowDog.Data.Store.Ets,
        indexes: [:status],
        persistence: [strategy: :toml, path: "data/test.toml"]
      )
    end

    test "generates collection/0 function" do
      Code.ensure_loaded!(TestModule)
      assert function_exported?(TestModule, :collection, 0)
    end

    test "collection/0 returns a %Collection{}" do
      assert %Collection{} = TestModule.collection()
    end

    test "collection has correct name" do
      assert TestModule.collection().name == :test_items
    end

    test "collection has correct key_field" do
      assert TestModule.collection().key_field == :name
    end

    test "collection has correct indexes" do
      assert TestModule.collection().indexes == [:status]
    end

    test "collection has persistence config" do
      assert %{strategy: :toml, path: "data/test.toml"} = TestModule.collection().persistence
    end
  end
end
