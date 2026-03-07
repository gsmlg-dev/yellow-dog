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
end
