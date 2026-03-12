defmodule YellowDogIdentity.Trust.Token.VerifierTest do
  use ExUnit.Case, async: false

  alias YellowDogIdentity.Trust.Token.Verifier
  alias YellowDogIdentity.Token
  alias YellowDogIdentity.Registry

  describe "verify/1 skip cases" do
    test "skips when authorization is nil" do
      context = %{authorization: nil, hostname: "node-01"}
      assert {:skip, :not_applicable} = Verifier.verify(context)
    end

    test "skips when authorization is empty string" do
      context = %{authorization: "", hostname: "node-01"}
      assert {:skip, :not_applicable} = Verifier.verify(context)
    end

    test "skips when context lacks authorization key" do
      context = %{hostname: "node-01", source_ip: {127, 0, 0, 1}}
      assert {:skip, :not_applicable} = Verifier.verify(context)
    end
  end

  describe "verify/1 without Registry" do
    test "returns untrusted when no tokens exist (Registry not started)" do
      context = %{authorization: "Bearer some-random-token", hostname: "node-01"}
      assert {:untrusted, :invalid_token} = Verifier.verify(context)
    end
  end

  describe "verify/1 with Registry" do
    setup do
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "yd_verifier_test_#{:erlang.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp_dir)

      # Stop the identity supervisor (which manages Registry) if running
      if sup = Process.whereis(YellowDogIdentity.Supervisor) do
        Supervisor.stop(sup)
      end

      # Stop any pre-existing registry (started by yellow_dog app)
      if pid = Process.whereis(YellowDogIdentity.Registry) do
        GenServer.stop(pid)
      end

      {:ok, pid} = Registry.start_link(data_dir: tmp_dir, name: YellowDogIdentity.Registry)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
        File.rm_rf!(tmp_dir)
      end)

      %{registry: pid, tmp_dir: tmp_dir}
    end

    test "returns trusted with valid token and matching hostname" do
      {:ok, token, raw_token} = Token.create(%{hostname_pattern: "node-*", role: "worker"})
      :ok = Registry.put_token(token)

      context = %{authorization: "Bearer #{raw_token}", hostname: "node-01"}
      assert {:trusted, :token_verified, evidence} = Verifier.verify(context)

      assert evidence.provider == :token
      assert evidence.token_id == token.id
      assert evidence.hostname_pattern == "node-*"
      assert evidence.role == "worker"
      assert %DateTime{} = evidence.verified_at
    end

    test "increments use_count after successful verification" do
      {:ok, token, raw_token} = Token.create(%{hostname_pattern: "*", max_uses: 5})
      :ok = Registry.put_token(token)

      context = %{authorization: "Bearer #{raw_token}", hostname: "any-host"}
      assert {:trusted, :token_verified, _} = Verifier.verify(context)

      # Check persisted token was updated
      {:ok, updated} = Registry.get_token(token.id)
      assert updated.use_count == 1
    end

    test "extracts Bearer token correctly" do
      {:ok, token, raw_token} = Token.create(%{hostname_pattern: "*"})
      :ok = Registry.put_token(token)

      # With "Bearer " prefix
      context = %{authorization: "Bearer #{raw_token}", hostname: "host-01"}
      assert {:trusted, :token_verified, _} = Verifier.verify(context)
    end

    test "accepts raw token without Bearer prefix" do
      {:ok, token, raw_token} = Token.create(%{hostname_pattern: "*"})
      :ok = Registry.put_token(token)

      # Without "Bearer " prefix — verifier still extracts and trims
      context = %{authorization: raw_token, hostname: "host-01"}
      assert {:trusted, :token_verified, _} = Verifier.verify(context)
    end

    test "returns untrusted with hostname mismatch" do
      {:ok, token, raw_token} = Token.create(%{hostname_pattern: "web-*"})
      :ok = Registry.put_token(token)

      context = %{authorization: "Bearer #{raw_token}", hostname: "db-01"}
      assert {:untrusted, :hostname_mismatch} = Verifier.verify(context)
    end

    test "returns untrusted with invalid token" do
      {:ok, token, _raw_token} = Token.create(%{hostname_pattern: "*"})
      :ok = Registry.put_token(token)

      context = %{authorization: "Bearer totally-wrong-token", hostname: "node-01"}
      assert {:untrusted, :invalid_token} = Verifier.verify(context)
    end

    test "returns untrusted with expired token" do
      {:ok, token, raw_token} = Token.create(%{hostname_pattern: "*", ttl_seconds: -1})
      :ok = Registry.put_token(token)

      context = %{authorization: "Bearer #{raw_token}", hostname: "node-01"}
      assert {:untrusted, :invalid_token} = Verifier.verify(context)
    end
  end
end
