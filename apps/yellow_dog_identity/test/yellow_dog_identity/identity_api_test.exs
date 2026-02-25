defmodule YellowDogIdentity.IdentityApiTest do
  @moduledoc """
  Tests for YellowDogIdentity public API edge cases not covered by integration_test.exs.

  Focuses on host_status/1, list_policies/0, token CRUD (create_token/1,
  list_tokens/0, revoke_token/1), registration validation errors, and sops export format.
  """

  use ExUnit.Case, async: false

  alias YellowDogIdentity.{Registry, Token}

  @valid_key "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBxRhNpqVVPZOFRZNvKGVfCjXN5US8MLXiEy1Ox7xDT6 test@host"
  @valid_age "age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p"

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "yd_identity_api_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)

    {:ok, pid} = Registry.start_link(data_dir: tmp_dir, name: YellowDogIdentity.Registry)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      File.rm_rf!(tmp_dir)
    end)

    %{tmp_dir: tmp_dir, registry: pid}
  end

  # ──────────────────────────────────────────────
  # host_status/1
  # ──────────────────────────────────────────────

  describe "host_status/1" do
    test "returns {:ok, map} with correct fields for an approved host" do
      {:ok, host} =
        YellowDogIdentity.register(%{
          hostname: "status-approved",
          ssh_pubkey: @valid_key,
          age_recipient: @valid_age
        })

      {:ok, _} = YellowDogIdentity.approve(host.id, "admin")

      assert {:ok, status_map} = YellowDogIdentity.host_status(host.id)
      assert status_map.id == host.id
      assert status_map.hostname == "status-approved"
      assert status_map.status == :approved
      assert status_map.trust_level == :unverified

      # Verify the map contains exactly these four keys
      assert Map.keys(status_map) |> Enum.sort() == [:hostname, :id, :status, :trust_level]
    end

    test "returns :not_found for non-existent host" do
      assert :not_found = YellowDogIdentity.host_status("does-not-exist-#{System.unique_integer()}")
    end
  end

  # ──────────────────────────────────────────────
  # list_policies/0
  # ──────────────────────────────────────────────

  describe "list_policies/0" do
    test "returns a map with policies and default_action keys" do
      result = YellowDogIdentity.list_policies()

      assert is_map(result)
      assert Map.has_key?(result, :policies)
      assert Map.has_key?(result, :default_action)
      assert is_list(result.policies)
      assert result.default_action in [:approve, :reject, :pending]
    end
  end

  # ──────────────────────────────────────────────
  # Token CRUD: create_token/1, list_tokens/0, revoke_token/1
  # ──────────────────────────────────────────────

  describe "create_token/1" do
    test "creates and persists a token, returns {:ok, token, raw_token}" do
      params = %{
        hostname_pattern: "web-*",
        max_uses: 5,
        created_by: "test-admin",
        ttl_seconds: 7200
      }

      assert {:ok, %Token{} = token, raw_token} = YellowDogIdentity.create_token(params)

      assert is_binary(token.id)
      assert is_binary(token.token_hash)
      assert is_binary(raw_token)
      assert token.hostname_pattern == "web-*"
      assert token.max_uses == 5
      assert token.created_by == "test-admin"
      assert token.use_count == 0
      assert %DateTime{} = token.expires_at
      assert %DateTime{} = token.created_at

      # Raw token should be non-empty and distinct from the hash
      assert byte_size(raw_token) > 0
      refute raw_token == token.token_hash
    end
  end

  describe "list_tokens/0" do
    test "returns tokens created via create_token" do
      assert YellowDogIdentity.list_tokens() == []

      {:ok, token_a, _} =
        YellowDogIdentity.create_token(%{hostname_pattern: "a-*", created_by: "admin"})

      {:ok, token_b, _} =
        YellowDogIdentity.create_token(%{hostname_pattern: "b-*", created_by: "admin"})

      tokens = YellowDogIdentity.list_tokens()
      token_ids = Enum.map(tokens, & &1.id) |> Enum.sort()

      assert length(tokens) == 2
      assert Enum.sort([token_a.id, token_b.id]) == token_ids
    end
  end

  describe "revoke_token/1" do
    test "removes a token so it no longer appears in list_tokens" do
      {:ok, token, _} =
        YellowDogIdentity.create_token(%{hostname_pattern: "*", created_by: "admin"})

      assert Enum.any?(YellowDogIdentity.list_tokens(), &(&1.id == token.id))

      assert :ok = YellowDogIdentity.revoke_token(token.id)

      refute Enum.any?(YellowDogIdentity.list_tokens(), &(&1.id == token.id))
    end
  end

  # ──────────────────────────────────────────────
  # Registration validation errors
  # ──────────────────────────────────────────────

  describe "register/2 — validation errors" do
    test "missing hostname returns {:error, :hostname_required}" do
      params = %{ssh_pubkey: @valid_key, age_recipient: @valid_age}
      assert {:error, :hostname_required} = YellowDogIdentity.register(params)
    end

    test "empty hostname returns {:error, :hostname_required}" do
      params = %{hostname: "", ssh_pubkey: @valid_key, age_recipient: @valid_age}
      assert {:error, :hostname_required} = YellowDogIdentity.register(params)
    end

    test "invalid pubkey format returns {:error, :invalid_pubkey}" do
      params = %{hostname: "bad-key-host", ssh_pubkey: "not-a-valid-key", age_recipient: @valid_age}
      assert {:error, :invalid_pubkey} = YellowDogIdentity.register(params)
    end

    test "invalid age_recipient returns {:error, :invalid_age_recipient}" do
      params = %{hostname: "bad-age-host", ssh_pubkey: @valid_key, age_recipient: "notage1xxx"}
      assert {:error, :invalid_age_recipient} = YellowDogIdentity.register(params)
    end

    test "too-short age_recipient returns {:error, :invalid_age_recipient}" do
      params = %{hostname: "short-age", ssh_pubkey: @valid_key, age_recipient: "age1short"}
      assert {:error, :invalid_age_recipient} = YellowDogIdentity.register(params)
    end
  end

  # ──────────────────────────────────────────────
  # export_recipients/1 — sops format
  # ──────────────────────────────────────────────

  describe "export_recipients/1 with format: :sops" do
    test "returns sops format string with creation_rules for approved host" do
      {:ok, host} =
        YellowDogIdentity.register(%{
          hostname: "sops-api-host",
          ssh_pubkey: @valid_key,
          age_recipient: @valid_age
        })

      {:ok, _} = YellowDogIdentity.approve(host.id)

      sops = YellowDogIdentity.export_recipients(format: :sops)

      assert is_binary(sops)
      assert sops =~ "creation_rules:"
      assert sops =~ "age: >-"
      assert sops =~ @valid_age
    end

    test "returns empty sops format when no approved hosts exist" do
      sops = YellowDogIdentity.export_recipients(format: :sops)

      assert sops =~ "creation_rules:"
      assert sops =~ "age: \"\""
      refute sops =~ @valid_age
    end
  end
end
