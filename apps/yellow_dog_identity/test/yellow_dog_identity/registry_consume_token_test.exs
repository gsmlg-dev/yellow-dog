defmodule YellowDogIdentity.RegistryConsumeTokenTest do
  use ExUnit.Case

  alias YellowDogIdentity.{Token, Registry}

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "yd_consume_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    {:ok, pid} =
      Registry.start_link(
        data_dir: tmp_dir,
        name: :"consume_registry_#{:erlang.unique_integer([:positive])}"
      )

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      File.rm_rf!(tmp_dir)
    end)

    %{registry: pid, tmp_dir: tmp_dir}
  end

  describe "consume_token atomicity" do
    test "successfully consumes a valid token", %{registry: pid} do
      {:ok, token, raw} = Token.create(%{hostname_pattern: "node-*", max_uses: 1})
      :ok = GenServer.call(pid, {:put_token, token})

      assert {:ok, consumed} = GenServer.call(pid, {:consume_token, raw, "node-01"})
      assert consumed.use_count == 1
    end

    test "rejects token after max_uses exhausted", %{registry: pid} do
      {:ok, token, raw} = Token.create(%{hostname_pattern: "*", max_uses: 1})
      :ok = GenServer.call(pid, {:put_token, token})

      assert {:ok, _} = GenServer.call(pid, {:consume_token, raw, "host-a"})
      assert {:error, :invalid_token} = GenServer.call(pid, {:consume_token, raw, "host-b"})
    end

    test "multi-use token allows exactly max_uses consumptions", %{registry: pid} do
      {:ok, token, raw} = Token.create(%{hostname_pattern: "*", max_uses: 3})
      :ok = GenServer.call(pid, {:put_token, token})

      for i <- 1..3 do
        assert {:ok, consumed} = GenServer.call(pid, {:consume_token, raw, "host-#{i}"})
        assert consumed.use_count == i
      end

      # 4th should fail
      assert {:error, :invalid_token} = GenServer.call(pid, {:consume_token, raw, "host-4"})
    end

    test "rejects invalid raw token", %{registry: pid} do
      {:ok, token, _raw} = Token.create(%{hostname_pattern: "*"})
      :ok = GenServer.call(pid, {:put_token, token})

      assert {:error, :invalid_token} = GenServer.call(pid, {:consume_token, "wrong-token", "host"})
    end

    test "rejects hostname that doesn't match pattern", %{registry: pid} do
      {:ok, token, raw} = Token.create(%{hostname_pattern: "web-*", max_uses: 5})
      :ok = GenServer.call(pid, {:put_token, token})

      assert {:error, :hostname_mismatch} = GenServer.call(pid, {:consume_token, raw, "db-01"})
    end

    test "rejects expired token", %{registry: pid} do
      {:ok, token, raw} = Token.create(%{hostname_pattern: "*", ttl_seconds: 0})
      :ok = GenServer.call(pid, {:put_token, token})

      # Token already expired (ttl_seconds=0 means expires immediately)
      Process.sleep(10)
      assert {:error, :invalid_token} = GenServer.call(pid, {:consume_token, raw, "host"})
    end

    test "persists use_count to disk after consumption", %{registry: pid, tmp_dir: tmp_dir} do
      {:ok, token, raw} = Token.create(%{hostname_pattern: "*", max_uses: 5})
      :ok = GenServer.call(pid, {:put_token, token})

      {:ok, _} = GenServer.call(pid, {:consume_token, raw, "host-1"})

      # Verify the TOML on disk has updated use_count
      token_file = Path.join([tmp_dir, "tokens", "#{token.id}.toml"])
      content = File.read!(token_file)
      assert content =~ "use_count = 1"
    end

    test "concurrent consumption serialized by GenServer", %{registry: pid} do
      {:ok, token, raw} = Token.create(%{hostname_pattern: "*", max_uses: 1})
      :ok = GenServer.call(pid, {:put_token, token})

      # Spawn 5 concurrent consumers — only 1 should succeed
      tasks =
        for i <- 1..5 do
          Task.async(fn ->
            GenServer.call(pid, {:consume_token, raw, "host-#{i}"})
          end)
        end

      results = Enum.map(tasks, &Task.await/1)
      successes = Enum.count(results, fn r -> match?({:ok, _}, r) end)
      failures = Enum.count(results, fn r -> match?({:error, _}, r) end)

      assert successes == 1
      assert failures == 4
    end

    test "returns error when no tokens exist", %{registry: pid} do
      assert {:error, :invalid_token} = GenServer.call(pid, {:consume_token, "any", "any"})
    end
  end
end
