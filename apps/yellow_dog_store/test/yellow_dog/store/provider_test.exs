defmodule YellowDog.Store.ProviderTest do
  use ExUnit.Case, async: false

  @moduletag :store_integration

  alias YellowDog.Store.Provider

  setup do
    YellowDog.StoreHelper.setup_store()
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

    test "rejects unsupported provider types" do
      assert {:error, :unsupported_provider} =
               Provider.put_config(%{name: "other", type: :gcp, credentials: %{}})
    end
  end
end
