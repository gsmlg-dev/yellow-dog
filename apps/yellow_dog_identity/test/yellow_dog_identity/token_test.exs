defmodule YellowDogIdentity.TokenTest do
  use ExUnit.Case, async: true

  alias YellowDogIdentity.Token

  describe "create/1" do
    test "creates a token with raw value" do
      params = %{hostname_pattern: "node-*", max_uses: 5, created_by: "admin"}
      assert {:ok, %Token{} = token, raw_token} = Token.create(params)

      assert token.hostname_pattern == "node-*"
      assert token.max_uses == 5
      assert token.use_count == 0
      assert token.created_by == "admin"
      assert is_binary(raw_token)
      assert byte_size(raw_token) > 20
    end

    test "creates single-use token by default" do
      assert {:ok, %Token{max_uses: 1}, _} = Token.create(%{})
    end

    test "rejects negative max_uses" do
      assert {:error, :invalid_max_uses} = Token.create(%{max_uses: -1})
    end

    test "rejects zero max_uses" do
      assert {:error, :invalid_max_uses} = Token.create(%{max_uses: 0})
    end

    test "rejects max_uses exceeding limit" do
      assert {:error, :invalid_max_uses} = Token.create(%{max_uses: 100_001})
    end

    test "rejects negative ttl_seconds" do
      assert {:error, :invalid_ttl} = Token.create(%{ttl_seconds: -1})
    end

    test "rejects ttl exceeding one year" do
      assert {:error, :invalid_ttl} = Token.create(%{ttl_seconds: 86_400 * 366})
    end

    test "rejects hostname_pattern exceeding max length" do
      long_pattern = String.duplicate("a", 257)
      assert {:error, :pattern_too_long} = Token.create(%{hostname_pattern: long_pattern})
    end

    test "allows zero ttl_seconds for immediately expiring token" do
      assert {:ok, %Token{}, _} = Token.create(%{ttl_seconds: 0})
    end
  end

  describe "verify/3" do
    test "accepts valid token for matching hostname" do
      {:ok, token, raw_token} = Token.create(%{hostname_pattern: "node-*"})
      assert :ok = Token.verify(token, raw_token, "node-01")
    end

    test "rejects invalid raw token" do
      {:ok, token, _raw_token} = Token.create(%{})
      assert {:error, :invalid_token} = Token.verify(token, "wrong-token", "host")
    end

    test "rejects expired token" do
      {:ok, token, raw_token} = Token.create(%{ttl_seconds: 0})
      token = %{token | expires_at: DateTime.add(DateTime.utc_now(), -60, :second)}
      assert {:error, :token_expired} = Token.verify(token, raw_token, "host")
    end

    test "rejects exhausted token" do
      {:ok, token, raw_token} = Token.create(%{max_uses: 1})
      exhausted = %{token | use_count: 1}
      assert {:error, :token_exhausted} = Token.verify(exhausted, raw_token, "host")
    end

    test "rejects hostname mismatch" do
      {:ok, token, raw_token} = Token.create(%{hostname_pattern: "web-*"})
      assert {:error, :hostname_mismatch} = Token.verify(token, raw_token, "db-01")
    end
  end

  describe "valid?/1" do
    test "returns true for fresh token" do
      {:ok, token, _} = Token.create(%{ttl_seconds: 3600})
      assert Token.valid?(token)
    end

    test "returns false for expired token" do
      {:ok, token, _} = Token.create(%{ttl_seconds: 0})
      token = %{token | expires_at: DateTime.add(DateTime.utc_now(), -60, :second)}
      refute Token.valid?(token)
    end

    test "returns false for exhausted token" do
      {:ok, token, _} = Token.create(%{max_uses: 1})
      refute Token.valid?(%{token | use_count: 1})
    end
  end

  describe "increment_use/1" do
    test "increments use count" do
      {:ok, token, _} = Token.create(%{})
      assert token.use_count == 0
      updated = Token.increment_use(token)
      assert updated.use_count == 1
    end
  end

  describe "hostname_matches?/2" do
    test "wildcard matches everything" do
      assert Token.hostname_matches?("anything", "*")
    end

    test "prefix pattern matches" do
      assert Token.hostname_matches?("node-01", "node-*")
      refute Token.hostname_matches?("web-01", "node-*")
    end

    test "exact match" do
      assert Token.hostname_matches?("node-01", "node-01")
      refute Token.hostname_matches?("node-02", "node-01")
    end
  end

  describe "to_toml_map/1 and from_toml_map/1" do
    test "round-trips token through TOML map" do
      {:ok, token, _} = Token.create(%{hostname_pattern: "node-*", role: "worker"})

      toml_map = Token.to_toml_map(token)
      assert %{"token" => %{"hostname_pattern" => "node-*"}} = toml_map

      {:ok, restored} = Token.from_toml_map(toml_map)
      assert restored.id == token.id
      assert restored.hostname_pattern == "node-*"
      assert restored.role == "worker"
    end

    test "from_toml_map rejects map without token section" do
      assert {:error, :missing_token_section} = Token.from_toml_map(%{"wrong" => %{}})
    end

    test "from_toml_map rejects non-map input" do
      assert {:error, :missing_token_section} = Token.from_toml_map("not a map")
      assert {:error, :missing_token_section} = Token.from_toml_map(nil)
    end

    test "from_toml_map returns error for missing required fields" do
      # token section present but missing required keys like id, token_hash, etc.
      incomplete = %{"token" => %{"id" => "some-id"}}
      assert {:error, {:invalid_toml_data, _msg}} = Token.from_toml_map(incomplete)
    end

    test "from_toml_map returns error for invalid datetime" do
      {:ok, token, _} = Token.create(%{hostname_pattern: "*"})
      toml_map = Token.to_toml_map(token)

      # Corrupt the expires_at field
      corrupted = put_in(toml_map, ["token", "expires_at"], "not-a-date")
      assert {:error, {:invalid_toml_data, _msg}} = Token.from_toml_map(corrupted)
    end

    test "round-trips token without optional role" do
      {:ok, token, _} = Token.create(%{hostname_pattern: "*"})
      assert is_nil(token.role)

      toml_map = Token.to_toml_map(token)
      {:ok, restored} = Token.from_toml_map(toml_map)
      assert is_nil(restored.role)
    end

    test "preserves use_count through round-trip" do
      {:ok, token, _} = Token.create(%{hostname_pattern: "*", max_uses: 5})
      used = Token.increment_use(token)
      assert used.use_count == 1

      toml_map = Token.to_toml_map(used)
      {:ok, restored} = Token.from_toml_map(toml_map)
      assert restored.use_count == 1
    end
  end
end
