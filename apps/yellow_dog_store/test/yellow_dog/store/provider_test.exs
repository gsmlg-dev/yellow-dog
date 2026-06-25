defmodule YellowDog.Store.ProviderTest do
  use ExUnit.Case, async: false

  @moduletag :store_integration

  alias YellowDog.Store.Backend
  alias YellowDog.Store.Backend.Ets, as: EtsBackend
  alias YellowDog.Store.Key
  alias YellowDog.Store.Provider

  defmodule DurableBackend do
    @behaviour YellowDog.Store.Backend

    @table :yellow_dog_store_provider_test_durable

    def reset do
      create_table()
      :ets.delete_all_objects(@table)
      :ok
    end

    @impl true
    def put(key, value, _opts \\ []) do
      :ets.insert(@table, {key, value})
      :ok
    end

    @impl true
    def get(key, _opts \\ []) do
      case :ets.lookup(@table, key) do
        [{^key, value}] -> {:ok, value}
        [] -> {:error, :not_found}
      end
    end

    @impl true
    def delete(key) do
      :ets.delete(@table, key)
      :ok
    end

    @impl true
    def put_if(key, value, opts \\ []) do
      case Keyword.fetch(opts, :expected) do
        {:ok, expected} ->
          case get(key) do
            {:ok, ^expected} -> put(key, value)
            {:error, :not_found} when is_nil(expected) -> put(key, value)
            _ -> {:error, :condition_failed}
          end

        :error ->
          {:error, :missing_condition}
      end
    end

    @impl true
    def prefix_scan(prefix, _opts \\ []) do
      entries =
        @table
        |> :ets.tab2list()
        |> Enum.filter(fn {key, _value} -> String.starts_with?(key, prefix) end)
        |> Enum.sort_by(fn {key, _value} -> key end)

      {:ok, entries}
    end

    @impl true
    def put_many(operations) do
      results =
        Map.new(operations, fn
          {key, value} ->
            put(key, value)
            {key, :ok}

          {key, value, _ttl} ->
            put(key, value)
            {key, :ok}
        end)

      {:ok, results}
    end

    defp create_table do
      case :ets.whereis(@table) do
        :undefined -> :ets.new(@table, [:set, :public, :named_table])
        _ref -> :ok
      end

      :ok
    end
  end

  setup do
    previous_persistence_backend =
      Application.get_env(:yellow_dog_store, :provider_persistence_backend)

    YellowDog.StoreHelper.setup_store()

    Application.put_env(:yellow_dog_store, :provider_persistence_backend, EtsBackend)

    on_exit(fn ->
      if previous_persistence_backend do
        Application.put_env(
          :yellow_dog_store,
          :provider_persistence_backend,
          previous_persistence_backend
        )
      else
        Application.delete_env(:yellow_dog_store, :provider_persistence_backend)
      end
    end)

    :ok
  end

  describe "cloud DNS provider configs" do
    test "stores and lists Cloudflare and Route 53 connectors" do
      assert :ok =
               Provider.put_config(%{
                 name: "cf-main",
                 type: :cloudflare,
                 credentials: %{api_token: "cf-token"},
                 zones: [],
                 enabled: true
               })

      assert :ok =
               Provider.put_config(%{
                 name: "aws-prod",
                 type: :route53,
                 credentials: %{
                   access_key_id: "AKIA...",
                   secret_access_key: "secret",
                   region: "us-east-1"
                 },
                 zones: [],
                 enabled: true
               })

      assert {:ok, %{name: "cf-main", type: :cloudflare}} = Provider.get_config("cf-main")
      assert {:ok, %{name: "aws-prod", type: :route53}} = Provider.get_config("aws-prod")

      assert {:ok, configs} = Provider.list_configs()
      assert [%{name: "aws-prod"}, %{name: "cf-main"}] = Enum.sort_by(configs, & &1.name)
    end

    test "lists configs from durable storage after the ETS cache is cleared" do
      Application.put_env(:yellow_dog_store, :provider_persistence_backend, DurableBackend)
      DurableBackend.reset()

      assert :ok =
               Provider.put_config(%{
                 name: "aws-prod",
                 type: :route53,
                 credentials: %{
                   access_key_id: "AKIA...",
                   secret_access_key: "secret",
                   region: "us-east-1"
                 },
                 zones: [],
                 enabled: true
               })

      :ets.delete_all_objects(EtsBackend.table())

      assert {:ok, [%{name: "aws-prod", type: :route53}]} = Provider.list_configs()
      assert {:ok, %{name: "aws-prod"}} = Backend.active().get(Key.provider_config("aws-prod"))
    end

    test "rejects unsupported provider types" do
      assert {:error, :unsupported_provider} =
               Provider.put_config(%{name: "other", type: :unknown, credentials: %{}})
    end
  end
end
