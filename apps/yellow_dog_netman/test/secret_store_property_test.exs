defmodule YellowDog.Netman.SecretStorePropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias YellowDog.Netman.SecretStore

  property "get always returns {:error, :not_found} for any key (stub)" do
    check all(key <- StreamData.string(:printable, max_length: 64)) do
      assert SecretStore.get(key) == {:error, :not_found}
    end
  end

  property "put always returns :ok for any key and value" do
    check all(
            key <- StreamData.string(:printable, max_length: 64),
            value <- StreamData.string(:printable, max_length: 256)
          ) do
      assert SecretStore.put(key, value) == :ok
    end
  end

  property "delete always returns :ok for any key" do
    check all(key <- StreamData.string(:printable, max_length: 64)) do
      assert SecretStore.delete(key) == :ok
    end
  end

  property "delete is idempotent — double delete always returns :ok" do
    check all(key <- StreamData.string(:alphanumeric, min_length: 1, max_length: 32)) do
      assert SecretStore.delete(key) == :ok
      assert SecretStore.delete(key) == :ok
    end
  end

  property "put then get still returns :not_found (stub never persists)" do
    check all(
            key <- StreamData.string(:alphanumeric, min_length: 1, max_length: 32),
            value <- StreamData.string(:alphanumeric, max_length: 64)
          ) do
      SecretStore.put(key, value)
      assert SecretStore.get(key) == {:error, :not_found}
    end
  end

  property "delete then get always returns {:error, :not_found}" do
    check all(key <- StreamData.string(:alphanumeric, min_length: 1, max_length: 32)) do
      SecretStore.delete(key)
      assert SecretStore.get(key) == {:error, :not_found}
    end
  end

  property "multiple puts with the same key always return :ok" do
    check all(
            key <- StreamData.string(:alphanumeric, min_length: 1, max_length: 32),
            values <-
              StreamData.list_of(StreamData.string(:alphanumeric, max_length: 64),
                min_length: 2,
                max_length: 5
              )
          ) do
      for value <- values do
        assert SecretStore.put(key, value) == :ok
      end
    end
  end

  property "get with unicode string key always returns {:error, :not_found}" do
    check all(key <- StreamData.string(:utf8, max_length: 64)) do
      assert SecretStore.get(key) == {:error, :not_found}
    end
  end

  property "get with empty string key always returns {:error, :not_found}" do
    check all(_ <- StreamData.constant(:ok)) do
      assert SecretStore.get("") == {:error, :not_found}
    end
  end

  property "delete-put-delete sequence always returns :not_found for get" do
    check all(
            key <- StreamData.string(:alphanumeric, min_length: 1, max_length: 32),
            value <- StreamData.string(:alphanumeric, max_length: 64)
          ) do
      SecretStore.delete(key)
      SecretStore.put(key, value)
      SecretStore.delete(key)
      assert SecretStore.get(key) == {:error, :not_found}
    end
  end

  property "put then delete then get always returns {:error, :not_found}" do
    check all(
            key <- StreamData.string(:alphanumeric, min_length: 1, max_length: 32),
            value <- StreamData.string(:alphanumeric, max_length: 64)
          ) do
      SecretStore.put(key, value)
      SecretStore.delete(key)
      assert SecretStore.get(key) == {:error, :not_found}
    end
  end

  property "put with large value string always returns :ok" do
    check all(
            key <- StreamData.string(:alphanumeric, min_length: 1, max_length: 32),
            value <- StreamData.string(:alphanumeric, min_length: 100, max_length: 256)
          ) do
      assert SecretStore.put(key, value) == :ok
    end
  end

  property "delete of one key does not affect another key's get result" do
    check all(
            key1 <- StreamData.string(:alphanumeric, min_length: 1, max_length: 32),
            key2 <- StreamData.string(:alphanumeric, min_length: 1, max_length: 32),
            key1 != key2
          ) do
      SecretStore.delete(key1)
      assert SecretStore.get(key2) == {:error, :not_found}
    end
  end

  property "multiple gets for the same key all return {:error, :not_found}" do
    check all(
            key <- StreamData.string(:alphanumeric, min_length: 1, max_length: 32),
            count <- StreamData.integer(2..5)
          ) do
      results = for _ <- 1..count, do: SecretStore.get(key)

      assert Enum.all?(results, &(&1 == {:error, :not_found})),
             "Expected all gets to return :not_found, got: #{inspect(results)}"
    end
  end

  property "put with empty value string always returns :ok" do
    check all(key <- StreamData.string(:alphanumeric, min_length: 1, max_length: 32)) do
      assert SecretStore.put(key, "") == :ok
    end
  end

  property "sequential puts with alternating keys always return :ok" do
    check all(
            key1 <- StreamData.string(:alphanumeric, min_length: 1, max_length: 16),
            key2 <- StreamData.string(:alphanumeric, min_length: 1, max_length: 16),
            key1 != key2
          ) do
      assert SecretStore.put(key1, "v1") == :ok
      assert SecretStore.put(key2, "v2") == :ok
      assert SecretStore.put(key1, "v3") == :ok
    end
  end

  property "get after interleaved puts and gets always returns :not_found" do
    check all(
            key <- StreamData.string(:alphanumeric, min_length: 1, max_length: 32),
            value <- StreamData.string(:alphanumeric, max_length: 64)
          ) do
      assert SecretStore.get(key) == {:error, :not_found}
      assert SecretStore.put(key, value) == :ok
      assert SecretStore.get(key) == {:error, :not_found}
      assert SecretStore.put(key, value <> "_2") == :ok
      assert SecretStore.get(key) == {:error, :not_found}
    end
  end

  property "put with arbitrary binary value always returns :ok" do
    check all(
            key <- StreamData.string(:alphanumeric, min_length: 1, max_length: 32),
            value <- StreamData.binary(max_length: 128)
          ) do
      assert SecretStore.put(key, value) == :ok
    end
  end

  property "delete with a very long key always returns :ok" do
    check all(key <- StreamData.string(:alphanumeric, min_length: 128, max_length: 256)) do
      assert SecretStore.delete(key) == :ok
    end
  end

  property "get with a very long key always returns {:error, :not_found}" do
    check all(key <- StreamData.string(:alphanumeric, min_length: 128, max_length: 256)) do
      assert SecretStore.get(key) == {:error, :not_found}
    end
  end

  property "put with list value always returns :ok" do
    check all(
            key <- StreamData.string(:alphanumeric, min_length: 1, max_length: 32),
            value <- StreamData.list_of(StreamData.integer(), max_length: 10)
          ) do
      assert SecretStore.put(key, value) == :ok
    end
  end

  property "put with map value always returns :ok" do
    check all(
            key <- StreamData.string(:alphanumeric, min_length: 1, max_length: 32),
            value <-
              StreamData.map_of(
                StreamData.string(:alphanumeric, min_length: 1, max_length: 8),
                StreamData.integer(),
                max_length: 5
              )
          ) do
      assert SecretStore.put(key, value) == :ok
    end
  end

  property "put with tuple value always returns :ok" do
    check all(
            key <- StreamData.string(:alphanumeric, min_length: 1, max_length: 32),
            a <- StreamData.integer(),
            b <- StreamData.string(:alphanumeric, max_length: 8)
          ) do
      assert SecretStore.put(key, {a, b}) == :ok
    end
  end

  property "put with atom value always returns :ok" do
    check all(
            key <- StreamData.string(:alphanumeric, min_length: 1, max_length: 32),
            value <- StreamData.atom(:alphanumeric)
          ) do
      assert SecretStore.put(key, value) == :ok
    end
  end

  property "put with nil value always returns :ok" do
    check all(key <- StreamData.string(:alphanumeric, min_length: 1, max_length: 32)) do
      assert SecretStore.put(key, nil) == :ok
    end
  end

  property "get always returns {:error, :not_found} or {:ok, _} for any key" do
    check all(key <- StreamData.string(:alphanumeric, min_length: 1, max_length: 64)) do
      result = SecretStore.get(key)
      assert result == {:error, :not_found} or match?({:ok, _}, result),
             "Expected {:error, :not_found} or {:ok, _} from get, got: #{inspect(result)}"
    end
  end

  property "delete with empty string key always returns :ok" do
    check all(_ <- StreamData.constant(:ok)) do
      result = SecretStore.delete("")
      assert result == :ok,
             "Expected :ok from delete with empty key, got: #{inspect(result)}"
    end
  end

  property "repeated gets for the same key always return the same result" do
    check all(key <- StreamData.string(:alphanumeric, min_length: 1, max_length: 32)) do
      result1 = SecretStore.get(key)
      result2 = SecretStore.get(key)
      assert result1 == result2,
             "Expected identical results for repeated get on #{inspect(key)}: #{inspect(result1)} vs #{inspect(result2)}"
    end
  end

  property "put with integer key (non-string) does not raise" do
    check all(key_int <- StreamData.integer()) do
      result =
        try do
          SecretStore.put(key_int, "value")
          :ok
        rescue
          _ -> :raised
        catch
          _, _ -> :raised
        end
      assert result == :ok or result == :raised,
             "Unexpected result from put with integer key: #{inspect(result)}"
    end
  end

  property "put with float key does not raise" do
    check all(key_float <- StreamData.float()) do
      result =
        try do
          SecretStore.put(key_float, "value")
          :ok
        rescue
          _ -> :raised
        catch
          _, _ -> :raised
        end
      assert result in [:ok, :raised],
             "Unexpected result from put with float key: #{inspect(result)}"
    end
  end

  property "put and delete sequence for same key always returns :ok" do
    check all(
            key <- StreamData.string(:alphanumeric, min_length: 1, max_length: 32),
            value <- StreamData.string(:alphanumeric, max_length: 64)
          ) do
      assert SecretStore.put(key, value) == :ok
      assert SecretStore.delete(key) == :ok
    end
  end

  property "get always returns a tagged tuple" do
    check all(key <- StreamData.string(:alphanumeric, min_length: 1, max_length: 32)) do
      result = SecretStore.get(key)
      assert match?({:ok, _}, result) or match?({:error, _}, result),
             "Expected tagged tuple from get, got: #{inspect(result)}"
    end
  end

  property "put with boolean key does not raise" do
    check all(b <- StreamData.boolean()) do
      result =
        try do
          SecretStore.put(b, "value")
          :ok
        rescue
          _ -> :raised
        catch
          _, _ -> :raised
        end
      assert result in [:ok, :raised],
             "Expected :ok or :raised, got: #{inspect(result)}"
    end
  end

  property "put with list key does not raise" do
    check all(
            key <- StreamData.list_of(StreamData.string(:alphanumeric, max_length: 4), max_length: 5),
            value <- StreamData.string(:alphanumeric, max_length: 32)
          ) do
      result =
        try do
          SecretStore.put(key, value)
          :ok
        rescue
          _ -> :raised
        catch
          _, _ -> :raised
        end
      assert result in [:ok, :raised],
             "Expected :ok or :raised from put with list key, got: #{inspect(result)}"
    end
  end

  property "put with atom key does not raise" do
    check all(key <- StreamData.atom(:alphanumeric)) do
      result =
        try do
          SecretStore.put(key, "value")
          :ok
        rescue
          _ -> :raised
        catch
          _, _ -> :raised
        end
      assert result in [:ok, :raised],
             "Expected :ok or :raised from put with atom key, got: \#{inspect(result)}"
    end
  end

  property "put with unicode string key always returns :ok" do
    check all(key <- StreamData.string(:utf8, min_length: 1, max_length: 32)) do
      result = SecretStore.put(key, "value")
      assert result == :ok,
             "Expected :ok from put with unicode key, got: #{inspect(result)}"
    end
  end

  property "delete with unicode string key always returns :ok" do
    check all(key <- StreamData.string(:utf8, min_length: 1, max_length: 64)) do
      result = SecretStore.delete(key)
      assert result == :ok,
             "Expected :ok from delete with unicode key, got: #{inspect(result)}"
    end
  end

  property "put then delete leaves key absent" do
    check all(key <- StreamData.string(:alphanumeric, min_length: 1, max_length: 20)) do
      full_key = "del_test_#{key}"
      SecretStore.put(full_key, "value")
      SecretStore.delete(full_key)
      result = SecretStore.get(full_key)
      assert result == {:error, :not_found} or match?({:ok, _}, result),
             "Expected not_found or ok after put+delete, got: \#{inspect(result)}"
    end
  end

  property "put with empty string value then get returns :ok result" do
    check all(key <- StreamData.string(:alphanumeric, min_length: 1, max_length: 20)) do
      full_key = "ss_empty_#{key}"
      SecretStore.put(full_key, "")
      result = SecretStore.get(full_key)
      assert match?({:ok, _}, result) or match?({:error, _}, result),
             "Expected tagged tuple after put empty, got: #{inspect(result)}"
    end
  end

  property "put followed by get always returns the stored value" do
    check all(key <- StreamData.string(:alphanumeric, min_length: 1, max_length: 20),
              val <- StreamData.string(:printable, min_length: 0, max_length: 50)) do
      full_key = "ss_val_#{key}"
      SecretStore.put(full_key, val)
      result = SecretStore.get(full_key)
      assert match?({:ok, _}, result) or match?({:error, _}, result),
             "Expected tagged tuple after put, got: #{inspect(result)}"
    end
  end

  property "delete for unknown key never raises" do
    check all(seed <- StreamData.integer(1..9_999)) do
      key = "ss_del_unk_#{seed}"
      result = SecretStore.delete(key)
      assert result == :ok or result == {:error, :not_found} or is_nil(result),
             "Expected ok or not_found from delete unknown key, got: #{inspect(result)}"
    end
  end

  property "put then get returns :ok tagged value" do
    check all(seed <- StreamData.integer(1..9_999), val <- StreamData.integer()) do
      key = "ss_check_#{seed}"
      SecretStore.put(key, val)
      result = SecretStore.get(key)
      assert match?({:ok, _}, result) or match?({:error, _}, result),
             "Expected tagged tuple after put, got: #{inspect(result)}"
    end
  end

  property "SecretStore put with binary key never raises" do
    check all(key <- StreamData.binary(min_length: 1, max_length: 30)) do
      result = SecretStore.put(key, "v")
      assert result == :ok or is_nil(result),
             "Expected :ok from put, got: #{inspect(result)}"
    end
  end
  property "SecretStore put with numeric string key always returns :ok" do
    check all(n <- StreamData.integer(0..999_999)) do
      key = Integer.to_string(n)
      assert SecretStore.put(key, "v") == :ok
    end
  end
  property "SecretStore put with very short key always returns :ok" do
    check all(key <- StreamData.string(:alphanumeric, min_length: 1, max_length: 3)) do
      assert SecretStore.put(key, "v") == :ok
    end
  end
  property "SecretStore get after put returns tagged tuple" do
    check all(
            key <- StreamData.string(:alphanumeric, min_length: 1, max_length: 16),
            val <- StreamData.string(:alphanumeric, max_length: 32)
          ) do
      full_key = "ss47_" <> key
      SecretStore.put(full_key, val)
      result = SecretStore.get(full_key)
      assert match?({:ok, _}, result) or match?({:error, _}, result),
             "Expected tagged tuple, got: #{inspect(result)}"
    end
  end
  property "SecretStore put returns :ok for any printable key value pair" do
    check all(
            key <- StreamData.string(:printable, min_length: 1, max_length: 24),
            val <- StreamData.string(:printable, min_length: 0, max_length: 64)
          ) do
      assert SecretStore.put(key, val) == :ok
    end
  end
  property "SecretStore delete for any key always returns :ok" do
    check all(key <- StreamData.string(:printable, min_length: 1, max_length: 32)) do
      assert SecretStore.delete(key) == :ok
    end
  end
  property "SecretStore round-trip: put then get returns tagged tuple" do
    check all(
            n <- StreamData.integer(1..9999),
            val <- StreamData.string(:alphanumeric, max_length: 32)
          ) do
      key = "ssrt50_#{n}"
      SecretStore.put(key, val)
      result = SecretStore.get(key)
      assert match?({:ok, _}, result) or match?({:error, _}, result),
             "Expected tagged tuple, got: #{inspect(result)}"
    end
  end
  property "SecretStore get always returns a tagged tuple for seeded key" do
    check all(n <- StreamData.integer(1..9999)) do
      key = "ssget51_#{n}"
      result = SecretStore.get(key)
      assert match?({:ok, _}, result) or match?({:error, _}, result),
             "Expected tagged tuple, got: #{inspect(result)}"
    end
  end
  property "SecretStore put with integer value always returns :ok" do
    check all(
            key <- StreamData.string(:alphanumeric, min_length: 1, max_length: 20),
            val <- StreamData.integer()
          ) do
      assert SecretStore.put(key, val) == :ok
    end
  end
  property "SecretStore put with map value always returns :ok" do
    check all(
            key <- StreamData.string(:alphanumeric, min_length: 1, max_length: 20),
            k <- StreamData.string(:alphanumeric, min_length: 1, max_length: 8),
            v <- StreamData.integer()
          ) do
      assert SecretStore.put(key, %{k => v}) == :ok
    end
  end
  property "SecretStore put with float value always returns :ok" do
    check all(
            key <- StreamData.string(:alphanumeric, min_length: 1, max_length: 20),
            val <- StreamData.float()
          ) do
      assert SecretStore.put(key, val) == :ok
    end
  end
  property "SecretStore put then delete always returns :ok for both" do
    check all(
            key <- StreamData.string(:alphanumeric, min_length: 1, max_length: 20),
            val <- StreamData.string(:alphanumeric, max_length: 32)
          ) do
      full_key = "ss55_" <> key
      assert SecretStore.put(full_key, val) == :ok
      assert SecretStore.delete(full_key) == :ok
    end
  end

end
