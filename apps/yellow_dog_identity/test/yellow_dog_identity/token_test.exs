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
      {:ok, token, raw_token} = Token.create(%{ttl_seconds: -1})
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
      {:ok, token, _} = Token.create(%{ttl_seconds: -1})
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
  end
end
