defmodule YellowDog.DnsProvider.ConfigTest do
  use ExUnit.Case, async: true

  alias YellowDog.DnsProvider.Config

  describe "new/1" do
    test "creates config with all required fields" do
      assert {:ok, config} =
               Config.new(%{
                 name: "aws-prod",
                 type: :aws,
                 credentials: %{access_key_id: "AKIA...", secret_access_key: "secret"},
                 sync_interval: 300,
                 zones: ["example.com."],
                 conflict_strategy: :local_wins
               })

      assert config.name == "aws-prod"
      assert config.type == :aws
      assert config.sync_interval == 300
      assert config.conflict_strategy == :local_wins
      assert config.enabled == true
    end

    test "returns error for missing required fields" do
      assert {:error, :missing_name} = Config.new(%{type: :aws})
    end

    test "returns error for invalid type" do
      assert {:error, :invalid_type} =
               Config.new(%{name: "x", type: :unknown, zones: ["."]})
    end

    test "returns error for invalid conflict strategy" do
      assert {:error, :invalid_conflict_strategy} =
               Config.new(%{
                 name: "x",
                 type: :aws,
                 zones: ["."],
                 conflict_strategy: :invalid
               })
    end

    test "defaults sync_interval to 300" do
      assert {:ok, config} =
               Config.new(%{name: "x", type: :cloudflare, zones: ["."]})

      assert config.sync_interval == 300
    end

    test "defaults conflict_strategy to :local_wins" do
      assert {:ok, config} =
               Config.new(%{name: "x", type: :cloudflare, zones: ["."]})

      assert config.conflict_strategy == :local_wins
    end
  end

  describe "to_map/1 and from_map/1" do
    test "roundtrips through map serialization" do
      {:ok, original} =
        Config.new(%{
          name: "cf",
          type: :cloudflare,
          credentials: %{api_token: "tok"},
          sync_interval: 600,
          zones: ["site.com."],
          conflict_strategy: :manual
        })

      map = Config.to_map(original)
      assert is_map(map)
      assert map.name == "cf"

      {:ok, restored} = Config.from_map(map)
      assert restored == original
    end
  end
end
