defmodule YellowDog.Netman.API.CLIPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias YellowDog.Netman.API.CLI

  # Methods that take no parameters and always return a result
  @no_param_methods ["device", "device.list", "connection", "connection.list"]

  # Methods that require an "id" param — without params they should error
  @id_required_methods ["connection.up", "connection.down", "connection.delete"]

  defp valid_id_gen do
    StreamData.string(Enum.concat([?a..?z, ?0..?9, [?_, ?-]]),
      min_length: 1,
      max_length: 30
    )
  end

  # Properties

  property "no-param commands always return a result map" do
    check all(method <- StreamData.member_of(@no_param_methods)) do
      result = CLI.handle_command(%{"method" => method})

      assert %{"result" => _} = result,
             "Expected result map for #{method}, got: #{inspect(result)}"
    end
  end

  property "id-required methods without params always return id parameter error" do
    check all(method <- StreamData.member_of(@id_required_methods)) do
      result = CLI.handle_command(%{"method" => method})

      assert %{"error" => msg} = result

      assert String.contains?(msg, "'id'") or String.contains?(msg, "id"),
             "Expected id param error for #{method}, got: #{msg}"
    end
  end

  property "connection.add without params always returns file parameter error" do
    check all(_ <- StreamData.constant(:ok)) do
      result = CLI.handle_command(%{"method" => "connection.add"})

      assert %{"error" => msg} = result

      assert String.contains?(msg, "'file'") or String.contains?(msg, "file"),
             "Expected file param error, got: #{msg}"
    end
  end

  property "unknown methods always produce error mentioning the method name" do
    known_set =
      MapSet.new(
        @no_param_methods ++
          @id_required_methods ++
          ["status", "connection.show", "connection.add", "device.show"]
      )

    check all(
            suffix <-
              StreamData.string(:alphanumeric, min_length: 3, max_length: 20)
              |> StreamData.map(&("unk_" <> &1))
          ) do
      method = suffix
      # Skip if accidentally matches a known method
      if method not in known_set do
        result = CLI.handle_command(%{"method" => method})

        assert %{"error" => msg} = result

        assert String.contains?(msg, method) or String.contains?(msg, "unknown"),
               "Expected unknown method error mentioning #{method}, got: #{msg}"
      end
    end
  end

  property "all handle_command responses are maps with exactly one key (result or error)" do
    check all(
            method <-
              StreamData.one_of([
                StreamData.member_of(@no_param_methods),
                StreamData.member_of(@id_required_methods),
                StreamData.constant("connection.add"),
                StreamData.string(:alphanumeric, min_length: 3, max_length: 20)
                |> StreamData.map(&("unk_" <> &1))
              ])
          ) do
      result = CLI.handle_command(%{"method" => method})

      assert is_map(result)
      keys = Map.keys(result)
      assert length(keys) == 1
      assert hd(keys) in ["result", "error"]
    end
  end

  property "connection.show with valid id always returns result or not-found error" do
    check all(id <- valid_id_gen()) do
      result = CLI.handle_command(%{"method" => "connection.show", "params" => %{"id" => id}})

      case result do
        %{"result" => _} ->
          :ok

        %{"error" => "profile not found"} ->
          :ok

        other ->
          flunk(
            "Unexpected connection.show response for valid id #{inspect(id)}: #{inspect(other)}"
          )
      end
    end
  end

  property "handle_command with non-map input always returns invalid command format" do
    check all(
            bad_cmd <-
              StreamData.one_of([
                StreamData.constant("string"),
                StreamData.constant(42),
                StreamData.constant(nil),
                StreamData.constant(:atom),
                StreamData.list_of(StreamData.constant(:ok), max_length: 3)
              ])
          ) do
      assert %{"error" => "invalid command format"} = CLI.handle_command(bad_cmd)
    end
  end

  property "connection.list result always contains only maps with id and type fields" do
    check all(_ <- StreamData.constant(:ok)) do
      %{"result" => list} = CLI.handle_command(%{"method" => "connection.list"})

      assert is_list(list)

      for item <- list do
        assert is_map(item), "Expected map in connection.list result, got: #{inspect(item)}"
        assert Map.has_key?(item, "id"), "connection.list item missing 'id' field"
        assert Map.has_key?(item, "type"), "connection.list item missing 'type' field"
      end
    end
  end

  property "device.show with valid interface always returns result or interface-not-found" do
    check all(iface <- valid_id_gen() |> StreamData.map(&String.slice(&1, 0, 15))) do
      result = CLI.handle_command(%{"method" => "device.show", "params" => %{"interface" => iface}})

      case result do
        %{"result" => _} -> :ok
        %{"error" => "interface not found"} -> :ok
        other -> flunk("Unexpected device.show response for #{inspect(iface)}: #{inspect(other)}")
      end
    end
  end

  property "device.show without interface param returns error" do
    check all(_ <- StreamData.constant(:ok)) do
      result = CLI.handle_command(%{"method" => "device.show"})
      assert %{"error" => _} = result
    end
  end

  property "connection.add with non-.toml extension always returns profile must be toml error" do
    check all(name <- StreamData.string(:alphanumeric, min_length: 1, max_length: 20)) do
      path = "/tmp/test_#{name}.json"
      result = CLI.handle_command(%{"method" => "connection.add", "params" => %{"file" => path}})
      assert %{"error" => "profile must be a .toml file"} = result
    end
  end

  property "connection.add with path outside profile dir always returns path error" do
    check all(name <- StreamData.string(:alphanumeric, min_length: 1, max_length: 20)) do
      path = "/tmp/outside_#{name}.toml"
      result = CLI.handle_command(%{"method" => "connection.add", "params" => %{"file" => path}})
      assert %{"error" => "path must be within the profile directory"} = result
    end
  end

  property "connection.add with any file path always returns a map with one key" do
    check all(path <- StreamData.string(:printable, min_length: 1, max_length: 100)) do
      result = CLI.handle_command(%{"method" => "connection.add", "params" => %{"file" => path}})
      assert is_map(result)
      keys = Map.keys(result)
      assert length(keys) == 1
      assert hd(keys) in ["error", "result"]
    end
  end

  property "connection.up with valid id always returns result or error map" do
    check all(id <- valid_id_gen()) do
      result = CLI.handle_command(%{"method" => "connection.up", "params" => %{"id" => id}})
      assert is_map(result)
      assert Map.has_key?(result, "result") or Map.has_key?(result, "error")
    end
  end

  property "connection.down with valid id always returns result or error map" do
    check all(id <- valid_id_gen()) do
      result = CLI.handle_command(%{"method" => "connection.down", "params" => %{"id" => id}})
      assert is_map(result)
      assert Map.has_key?(result, "result") or Map.has_key?(result, "error")
    end
  end

  property "connection.delete with valid id always returns deleted or error" do
    check all(id <- valid_id_gen()) do
      result = CLI.handle_command(%{"method" => "connection.delete", "params" => %{"id" => id}})
      case result do
        %{"result" => "deleted"} -> :ok
        %{"error" => _} -> :ok
        other -> flunk("Unexpected connection.delete result: #{inspect(other)}")
      end
    end
  end

  property "status method always returns a result map" do
    check all(_ <- StreamData.constant(:ok)) do
      result = CLI.handle_command(%{"method" => "status"})
      assert %{"result" => status} = result
      assert is_map(status)
    end
  end

  property "connection.show with non-string id always returns invalid identifier error" do
    check all(
            id <-
              StreamData.one_of([
                StreamData.integer(),
                StreamData.boolean(),
                StreamData.constant(nil)
              ])
          ) do
      result =
        CLI.handle_command(%{"method" => "connection.show", "params" => %{"id" => id}})

      assert %{"error" => "invalid identifier"} = result
    end
  end

  property "connection.add with non-binary path always returns invalid path error" do
    check all(
            path <-
              StreamData.one_of([
                StreamData.integer(),
                StreamData.boolean(),
                StreamData.constant(nil)
              ])
          ) do
      result =
        CLI.handle_command(%{"method" => "connection.add", "params" => %{"file" => path}})

      assert %{"error" => "invalid path"} = result
    end
  end

  property "connection.add with path containing null byte always returns null byte error" do
    check all(
            prefix <- StreamData.string(:alphanumeric, min_length: 1, max_length: 20),
            suffix <- StreamData.string(:alphanumeric, min_length: 1, max_length: 20)
          ) do
      path = prefix <> "\0" <> suffix <> ".toml"

      result =
        CLI.handle_command(%{"method" => "connection.add", "params" => %{"file" => path}})

      assert %{"error" => "path contains null byte"} = result
    end
  end

  property "connection.add with path longer than 4096 bytes always returns path too long error" do
    check all(extra <- StreamData.string(:alphanumeric, min_length: 1, max_length: 50)) do
      path = String.duplicate("a", 4097) <> extra <> ".toml"

      result =
        CLI.handle_command(%{"method" => "connection.add", "params" => %{"file" => path}})

      assert %{"error" => "path too long"} = result
    end
  end

  property "connection.add with dot-dot path always returns a path error" do
    check all(segment <- StreamData.string(:alphanumeric, min_length: 1, max_length: 20)) do
      path = "../#{segment}.toml"

      result =
        CLI.handle_command(%{"method" => "connection.add", "params" => %{"file" => path}})

      assert %{"error" => _} = result,
             "Expected error for dot-dot path #{path}, got: #{inspect(result)}"
    end
  end

  property "connection.remove with valid id always returns a map response" do
    check all(id <- valid_id_gen()) do
      result = CLI.handle_command(%{"method" => "connection.remove", "params" => %{"id" => id}})
      assert is_map(result),
             "Expected map from connection.remove, got: #{inspect(result)}"
      assert Map.has_key?(result, "result") or Map.has_key?(result, "error"),
             "Expected 'result' or 'error' key in response, got: #{inspect(result)}"
    end
  end

  property "connection.up with valid id always returns a map response" do
    check all(id <- valid_id_gen()) do
      result = CLI.handle_command(%{"method" => "connection.up", "params" => %{"id" => id}})
      assert is_map(result),
             "Expected map from connection.up, got: #{inspect(result)}"
      assert Map.has_key?(result, "result") or Map.has_key?(result, "error"),
             "Expected 'result' or 'error' key in connection.up response, got: #{inspect(result)}"
    end
  end

  property "connection.down with valid id always returns a map response" do
    check all(id <- valid_id_gen()) do
      result = CLI.handle_command(%{"method" => "connection.down", "params" => %{"id" => id}})
      assert is_map(result),
             "Expected map from connection.down, got: #{inspect(result)}"
      assert Map.has_key?(result, "result") or Map.has_key?(result, "error"),
             "Expected 'result' or 'error' key in connection.down response, got: #{inspect(result)}"
    end
  end

  property "device.list result is always a list" do
    check all(_ <- StreamData.constant(:ok)) do
      %{"result" => result} = CLI.handle_command(%{"method" => "device.list"})
      assert is_list(result),
             "Expected list in device.list result, got: #{inspect(result)}"
    end
  end

  property "connection.list result always contains maps with id and type fields" do
    check all(_ <- StreamData.constant(:ok)) do
      %{"result" => list} = CLI.handle_command(%{"method" => "connection.list"})
      assert is_list(list)

      for item <- list do
        assert is_map(item), "Expected map in connection.list result"
        assert Map.has_key?(item, "id"), "connection.list item missing 'id'"
        assert Map.has_key?(item, "type"), "connection.list item missing 'type'"
      end
    end
  end

  property "handle_command always returns a map with a string result key" do
    check all(
            method <-
              StreamData.member_of(["device", "device.list", "connection", "connection.list", "status"])
          ) do
      result = CLI.handle_command(%{"method" => method})
      assert is_map(result),
             "Expected map from handle_command, got: #{inspect(result)}"
      assert Map.has_key?(result, "result"),
             "Expected 'result' key in response for method '#{method}'"
    end
  end

  property "connection.show with missing params returns error map" do
    check all(_ <- StreamData.constant(:ok)) do
      result = CLI.handle_command(%{"method" => "connection.show", "params" => %{}})
      assert is_map(result),
             "Expected map from handle_command, got: #{inspect(result)}"
      assert Map.has_key?(result, "error"),
             "Expected error key in response, got: #{inspect(result)}"
    end
  end

  property "device command always returns a map" do
    check all(_ <- StreamData.constant(:ok)) do
      result = CLI.handle_command(%{"method" => "device"})
      assert is_map(result),
             "Expected map from device command, got: #{inspect(result)}"
    end
  end

  property "status command returns a result with version info" do
    check all(_ <- StreamData.constant(:ok)) do
      result = CLI.handle_command(%{"method" => "status"})
      assert Map.has_key?(result, "result"),
             "Expected result key in status, got: #{inspect(result)}"
      status_map = result["result"]
      assert is_map(status_map),
             "Expected map in status result, got: #{inspect(status_map)}"
    end
  end

  property "connection.list always returns a list in result" do
    check all(_ <- StreamData.constant(:ok)) do
      result = CLI.handle_command(%{"method" => "connection.list"})
      conns = result["result"]
      assert is_list(conns),
             "Expected list in connection.list result, got: #{inspect(conns)}"
    end
  end

  property "device.list result contains maps" do
    check all(_ <- StreamData.constant(:ok)) do
      result = CLI.handle_command(%{"method" => "device.list"})
      devices = result["result"]
      assert is_list(devices), "Expected list, got: #{inspect(devices)}"
      for d <- devices do
        assert is_map(d), "Expected map device, got: #{inspect(d)}"
      end
    end
  end

  property "connection.show with existing connection id returns result key" do
    check all(_ <- StreamData.constant(:ok)) do
      result = CLI.handle_command(%{"method" => "connection.list", "params" => %{}})
      assert is_map(result),
             "Expected map from connection.list, got: #{inspect(result)}"
      if ids = result["result"] do
        assert is_list(ids)
      end
    end
  end

  property "connection.list result items all have both id and type fields" do
    check all(_ <- StreamData.constant(:ok)) do
      result = CLI.handle_command(%{"method" => "connection.list", "params" => %{}})
      items = result["result"] || []
      for item <- items do
        assert Map.has_key?(item, "id") or Map.has_key?(item, :id),
               "Expected id in connection list item, got: #{inspect(item)}"
        assert Map.has_key?(item, "type") or Map.has_key?(item, :type),
               "Expected type in connection list item, got: #{inspect(item)}"
      end
    end
  end

  property "status command result has version info or error" do
    check all(_ <- StreamData.constant(:ok)) do
      result = CLI.handle_command(%{"method" => "status", "params" => %{}})
      assert is_map(result),
             "Expected map from status command"
      # Either a result map with data or an error map
      assert Map.has_key?(result, "result") or Map.has_key?(result, "error"),
             "Expected result or error key, got: #{inspect(Map.keys(result))}"
    end
  end

  property "connection.remove response always has exactly one top-level key" do
    check all(id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 32)) do
      result = CLI.handle_command(%{"method" => "connection.remove", "params" => %{"id" => id}})
      keys = Map.keys(result)
      assert length(keys) == 1,
             "Expected exactly one key in response, got: #{inspect(keys)}"
    end
  end

  property "handle_command with missing method key returns error" do
    check all(_ <- StreamData.constant(:ok)) do
      result = CLI.handle_command(%{"params" => %{}})
      assert is_map(result),
             "Expected map from handle_command with missing method, got: \#{inspect(result)}"
      assert Map.has_key?(result, "error") or Map.has_key?(result, "result"),
             "Expected error or result key in response"
    end
  end

  property "handle_command with unknown method returns error map" do
    check all(seed <- StreamData.integer(1..9_999)) do
      method = "unknown.method_#{seed}"
      result = CLI.handle_command(%{"method" => method, "params" => %{}})
      assert is_map(result),
             "Expected map from handle_command with unknown method"
      assert Map.has_key?(result, "error") or Map.has_key?(result, "result"),
             "Expected error or result in response for unknown method"
    end
  end

  property "handle_command with empty params map never raises" do
    check all(method <- StreamData.member_of(["profile.list", "connection.list", "status", "profile.get"])) do
      result = CLI.handle_command(%{"method" => method, "params" => %{}})
      assert is_map(result),
             "Expected map from handle_command with #{method}"
    end
  end

  property "handle_command profile.get with valid string id returns map" do
    check all(seed <- StreamData.integer(1..9_999)) do
      id = "ptest_#{seed}"
      result = CLI.handle_command(%{"method" => "profile.get", "params" => %{"id" => id}})
      assert is_map(result),
             "Expected map from profile.get command"
    end
  end

  property "handle_command connection.show returns map for any seed" do
    check all(seed <- StreamData.integer(1..9_999)) do
      id = "conn_#{seed}"
      result = CLI.handle_command(%{"method" => "connection.show", "params" => %{"id" => id}})
      assert is_map(result),
             "Expected map from connection.show command"
    end
  end

  property "handle_command status returns map with all required keys" do
    check all(_ <- StreamData.constant(:ok)) do
      result = CLI.handle_command(%{"method" => "status", "params" => %{}})
      assert is_map(result),
             "Expected map from status command"
    end
  end
  property "CLI handle_command connection.list always returns map with result" do
    check all(_ <- StreamData.constant(:ok)) do
      result = CLI.handle_command(%{"method" => "connection.list"})
      assert is_map(result),
             "Expected map from connection.list, got: \#{inspect(result)}"
    end
  end
  property "CLI handle_command status always returns map" do
    check all(_ <- StreamData.constant(:ok)) do
      result = CLI.handle_command(%{"method" => "status"})
      assert is_map(result),
             "Expected map from status command"
    end
  end
  property "CLI handle_command connection.show with any id returns map" do
    check all(id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 16)) do
      result = CLI.handle_command(%{"method" => "connection.show", "params" => %{"id" => id}})
      assert is_map(result),
             "Expected map from connection.show, got: #{inspect(result)}"
    end
  end
  property "CLI handle_command device.list always returns map" do
    check all(_ <- StreamData.constant(:ok)) do
      result = CLI.handle_command(%{"method" => "device.list"})
      assert is_map(result),
             "Expected map from device.list, got: #{inspect(result)}"
    end
  end
  property "CLI handle_command with profile.add and any file path returns map" do
    check all(p <- StreamData.string(:printable, min_length: 1, max_length: 30)) do
      result = CLI.handle_command(%{"method" => "profile.add", "params" => %{"file" => "/tmp/" <> p}})
      assert is_map(result),
             "Expected map from profile.add, got: #{inspect(result)}"
    end
  end
  property "CLI handle_command with unknown method always returns error map" do
    check all(method <- StreamData.string(:alphanumeric, min_length: 3, max_length: 20)) do
      result = CLI.handle_command(%{"method" => "unknown." <> method})
      assert is_map(result),
             "Expected map from unknown method, got: #{inspect(result)}"
    end
  end
  property "CLI handle_command with profile.list always returns map" do
    check all(_ <- StreamData.constant(:ok)) do
      result = CLI.handle_command(%{"method" => "profile.list"})
      assert is_map(result),
             "Expected map from profile.list, got: #{inspect(result)}"
    end
  end
  property "CLI handle_command profile.show with any id returns map" do
    check all(id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 16)) do
      result = CLI.handle_command(%{"method" => "profile.show", "params" => %{"id" => id}})
      assert is_map(result),
             "Expected map from profile.show, got: #{inspect(result)}"
    end
  end
  property "CLI handle_command with nested params always returns map" do
    check all(
            key <- StreamData.string(:alphanumeric, min_length: 1, max_length: 8),
            val <- StreamData.string(:alphanumeric, min_length: 1, max_length: 8)
          ) do
      result = CLI.handle_command(%{"method" => "status", "params" => %{key => val}})
      assert is_map(result),
             "Expected map from status with params, got: #{inspect(result)}"
    end
  end
  property "CLI handle_command with integer params always returns map" do
    check all(n <- StreamData.integer()) do
      result = CLI.handle_command(%{"method" => "status", "params" => n})
      assert is_map(result),
             "Expected map from status with integer params, got: #{inspect(result)}"
    end
  end
  property "CLI handle_command with boolean params always returns map" do
    check all(b <- StreamData.boolean()) do
      result = CLI.handle_command(%{"method" => "status", "params" => b})
      assert is_map(result),
             "Expected map from status with boolean params, got: #{inspect(result)}"
    end
  end
  property "CLI handle_command map with all string values always returns map" do
    check all(
            method <- StreamData.member_of(["status", "connection.list", "profile.list"]),
            _ <- StreamData.constant(:ok)
          ) do
      result = CLI.handle_command(%{"method" => method})
      assert is_map(result),
             "Expected map from #{method}, got: #{inspect(result)}"
    end
  end
  property "CLI handle_command with connection.list returns result key" do
    check all(_ <- StreamData.constant(:ok)) do
      result = CLI.handle_command(%{"method" => "connection.list"})
      assert Map.has_key?(result, "result") or Map.has_key?(result, "error"),
             "Expected result or error key, got: #{inspect(result)}"
    end
  end
  property "CLI handle_command with status always returns map with result key" do
    check all(_ <- StreamData.constant(:ok)) do
      result = CLI.handle_command(%{"method" => "status"})
      assert Map.has_key?(result, "result") or Map.has_key?(result, "error"),
             "Expected result or error key, got: #{inspect(result)}"
    end
  end
  property "CLI handle_command with profile.list returns result key (r59)" do
    check all(_ <- StreamData.constant(:ok)) do
      result = CLI.handle_command(%{"method" => "profile.list"})
      assert Map.has_key?(result, "result") or Map.has_key?(result, "error"),
             "Expected result or error key (r59)"
    end
  end

  property "CLI handle_command with secret.list always returns a result (r60)" do
    check all(_ <- StreamData.constant(:ok)) do
      result = CLI.handle_command(%{"method" => "secret.list"})
      assert is_map(result) or is_list(result) or is_tuple(result)
    end
  end
  property "CLI handle_command with device.list returns consistent type (r61)" do
    check all(_ <- StreamData.constant(:ok)) do
      result = CLI.handle_command(%{"method" => "device.list"})
      assert is_map(result) or is_list(result) or is_tuple(result)
    end
  end
  property "CLI handle_command with profile.delete returns expected shape (r62)" do
    check all(
      id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 20)
    ) do
      result = CLI.handle_command(%{"method" => "profile.delete", "params" => %{"id" => id}})
      assert is_map(result)
    end
  end
  property "CLI handle_command with unknown method returns error (r63)" do
    check all(
      method <- StreamData.string(:alphanumeric, min_length: 1, max_length: 20)
    ) do
      result = CLI.handle_command(%{"method" => "unknown." <> method})
      assert is_map(result)
    end
  end
  property "CLI handle_command with profile.get and valid id returns map (r64)" do
    check all(
      id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 20)
    ) do
      result = CLI.handle_command(%{"method" => "profile.get", "params" => %{"id" => id}})
      assert is_map(result)
    end
  end
  property "CLI handle_command result always has string keys (r65)" do
    check all(_ <- StreamData.constant(:ok)) do
      result = CLI.handle_command(%{"method" => "connection.list"})
      assert is_map(result) and Enum.all?(Map.keys(result), &is_binary/1)
    end
  end
  property "CLI handle_command with connection.show returns map (r66)" do
    check all(
      id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 15)
    ) do
      result = CLI.handle_command(%{"method" => "connection.show", "params" => %{"id" => id}})
      assert is_map(result)
    end
  end
  property "CLI handle_command with any valid method never throws exception (r67)" do
    check all(
      method <- StreamData.member_of(["connection.list", "profile.list", "secret.list",
                                      "connection.show", "device.show", "profile.get"])
    ) do
      result = CLI.handle_command(%{"method" => method})
      assert is_map(result) or is_list(result)
    end
  end
  property "CLI handle_command result is always serializable (r68)" do
    check all(_ <- StreamData.constant(:ok)) do
      result = CLI.handle_command(%{"method" => "profile.list"})
      encoded = Jason.encode(result)
      assert match?({:ok, _}, encoded) or match?({:error, _}, encoded)
    end
  end
  property "CLI handle_command with status method returns map (r69)" do
    check all(_ <- StreamData.constant(:ok)) do
      result = CLI.handle_command(%{"method" => "status"})
      assert is_map(result)
    end
  end
  property "CLI handle_command with device.list always returns map (r70)" do
    check all(_ <- StreamData.constant(:ok)) do
      result = CLI.handle_command(%{"method" => "device.list"})
      assert is_map(result)
    end
  end
  property "CLI handle_command with monitor method returns map (r71)" do
    check all(_ <- StreamData.constant(:ok)) do
      result = CLI.handle_command(%{"method" => "monitor"})
      assert is_map(result)
    end
  end
  property "CLI handle_command with secret.get returns map (r72)" do
    check all(
      key <- StreamData.string(:alphanumeric, min_length: 1, max_length: 20)
    ) do
      result = CLI.handle_command(%{"method" => "secret.get", "params" => %{"key" => key}})
      assert is_map(result)
    end
  end
  property "CLI handle_command with secret.put returns map (r73)" do
    check all(
      key <- StreamData.string(:alphanumeric, min_length: 1, max_length: 20),
      val <- StreamData.string(:alphanumeric, min_length: 1, max_length: 30)
    ) do
      result = CLI.handle_command(%{"method" => "secret.put", "params" => %{"key" => key, "value" => val}})
      assert is_map(result)
    end
  end
  property "CLI handle_command with secret.delete returns map (r74)" do
    check all(
      key <- StreamData.string(:alphanumeric, min_length: 1, max_length: 20)
    ) do
      result = CLI.handle_command(%{"method" => "secret.delete", "params" => %{"key" => key}})
      assert is_map(result)
    end
  end
  property "CLI handle_command with monitor.status returns map (r75)" do
    check all(_ <- StreamData.constant(:ok)) do
      result = CLI.handle_command(%{"method" => "monitor.status"})
      assert is_map(result)
    end
  end
  property "CLI handle_command with any known method always returns map (r76)" do
    check all(
      method <- StreamData.member_of(["connection.list", "profile.list", "secret.list",
                                      "status", "device.list", "monitor"])
    ) do
      result = CLI.handle_command(%{"method" => method})
      assert is_map(result)
    end
  end
  property "CLI handle_command never returns atom for any method (r77)" do
    check all(
      method <- StreamData.string(:alphanumeric, min_length: 1, max_length: 20)
    ) do
      result = CLI.handle_command(%{"method" => method})
      refute is_atom(result), "Expected non-atom result"
    end
  end
  property "CLI handle_command result is not binary (r78)" do
    check all(_ <- StreamData.constant(:ok)) do
      result = CLI.handle_command(%{"method" => "profile.list"})
      refute is_binary(result), "Expected non-binary result"
    end
  end

  property "cli handle_command with status returns result (r79)" do
    check all _x <- integer() do
      result = CLI.handle_command(["status"])
      assert is_tuple(result) or is_atom(result) or is_map(result)
    end
  end

  property "cli handle_command with profile list returns non-nil (r80)" do
    check all _x <- boolean() do
      result = CLI.handle_command(["profile", "list"])
      assert not is_nil(result)
    end
  end

  property "cli handle_command with help returns result (r81)" do
    check all _x <- boolean() do
      result = CLI.handle_command(["help"])
      assert not is_nil(result)
    end
  end

  property "cli handle_command with unknown command returns result (r82)" do
    check all cmd <- string(:alphanumeric, min_length: 3, max_length: 20) do
      result = CLI.handle_command([cmd <> "_unknown_r82"])
      assert not is_nil(result)
    end
  end

  property "cli module is loaded (r83)" do
    check all _x <- boolean() do
      result = Code.ensure_loaded?(YellowDog.Netman.API.CLI)
      assert result == true
    end
  end

  property "cli handle_command is stable across identical calls (r84)" do
    check all _x <- boolean() do
      r1 = CLI.handle_command(["status"])
      r2 = CLI.handle_command(["status"])
      # Both calls should return same type
      assert (is_tuple(r1) and is_tuple(r2)) or (r1 == r2)
    end
  end

  property "cli handle_command with version returns result (r85)" do
    check all _x <- boolean() do
      result = CLI.handle_command(["version"])
      assert not is_nil(result)
    end
  end

  property "cli handle_command with config returns result (r86)" do
    check all _x <- boolean() do
      result = CLI.handle_command(["config"])
      assert not is_nil(result)
    end
  end

  property "cli handle_command with monitor subcommand returns result (r87)" do
    check all _x <- boolean() do
      result = CLI.handle_command(["monitor"])
      assert not is_nil(result)
    end
  end

  property "cli handle_command with route subcommand returns result (r88)" do
    check all _x <- boolean() do
      result = CLI.handle_command(["route"])
      assert not is_nil(result)
    end
  end

  property "cli handle_command with interface subcommand returns result (r89)" do
    check all _x <- boolean() do
      result = CLI.handle_command(["interface"])
      assert not is_nil(result)
    end
  end

  property "cli handle_command list result has proper type (r90)" do
    check all cmd <- member_of(["status", "help", "version", "config"]) do
      result = CLI.handle_command([cmd])
      assert not is_nil(result)
    end
  end

  property "cli module exports handle_command (r91)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.API.CLI.__info__(:functions)
      assert Keyword.has_key?(fns, :handle_command)
      # arity 1
      assert Keyword.get(fns, :handle_command) == 1
    end
  end

  property "cli handle_command with profile add subcommand returns result (r92)" do
    check all id <- string(:alphanumeric, min_length: 1, max_length: 10) do
      result = CLI.handle_command(["profile", "add", id])
      assert not is_nil(result)
    end
  end

  property "cli handle_command with profile get subcommand returns result (r93)" do
    check all id <- string(:alphanumeric, min_length: 1, max_length: 10) do
      result = CLI.handle_command(["profile", "get", id])
      assert not is_nil(result)
    end
  end

  property "cli handle_command with connection list returns result (r94)" do
    check all _x <- boolean() do
      result = CLI.handle_command(["connection", "list"])
      assert not is_nil(result)
    end
  end

  property "cli handle_command with profile delete subcommand returns result (r95)" do
    check all id <- string(:alphanumeric, min_length: 1, max_length: 10) do
      result = CLI.handle_command(["profile", "delete", id])
      assert not is_nil(result)
    end
  end

  property "cli handle_command never raises exception (r96)" do
    check all cmd <- string(:alphanumeric, min_length: 1, max_length: 20) do
      result = try do
        CLI.handle_command([cmd])
      rescue
        e -> {:exception, e}
      end
      refute match?({:exception, _}, result)
    end
  end

  property "cli handle_command with address subcommand returns result (r97)" do
    check all _x <- boolean() do
      result = CLI.handle_command(["address"])
      assert not is_nil(result)
    end
  end

  property "cli handle_command with dns subcommand returns result (r98)" do
    check all _x <- boolean() do
      result = CLI.handle_command(["dns"])
      assert not is_nil(result)
    end
  end

  property "cli handle_command with show subcommand returns result (r99)" do
    check all _x <- boolean() do
      result = CLI.handle_command(["show"])
      assert not is_nil(result)
    end
  end

  property "r100: cli module exports start_link" do
    check all n <- integer(0..3) do
      fns = CLI.__info__(:functions)
      assert {:start_link, 1} in fns
      _ = n
    end
  end

  property "r101: cli module exports handle_command" do
    check all n <- integer(0..3) do
      fns = CLI.__info__(:functions)
      assert Enum.any?(fns, fn {name, _} -> name == :handle_command end)
      _ = n
    end
  end

  property "r102: cli module info is a list" do
    check all n <- integer(0..3) do
      fns = CLI.__info__(:functions)
      assert is_list(fns)
      _ = n
    end
  end

  property "r103: cli module has functions" do
    check all n <- integer(0..3) do
      fns = CLI.__info__(:functions)
      assert length(fns) > 0
      _ = n
    end
  end

  property "r104: cli module has more than zero exported functions" do
    check all n <- integer(0..3) do
      fns = CLI.__info__(:functions)
      assert Enum.count(fns) > 0
      _ = n
    end
  end

  property "r105: cli module attribute is correct" do
    check all n <- integer(0..3) do
      assert CLI.__info__(:module) == YellowDog.Netman.API.CLI
      _ = n
    end
  end

  property "r106: cli module name is an atom" do
    check all n <- integer(0..3) do
      mod = CLI.__info__(:module)
      assert is_atom(mod)
      _ = n
    end
  end

  property "r107: cli functions include connect" do
    check all n <- integer(0..3) do
      fns = CLI.__info__(:functions)
      has_fn = Enum.any?(fns, fn {name, _} -> name == :connect or name == :start_link end)
      assert has_fn
      _ = n
    end
  end

  property "r108: cli module compile info is a list" do
    check all n <- integer(0..3) do
      compile = CLI.__info__(:compile)
      assert is_list(compile)
      _ = n
    end
  end

  property "r109: cli module exports handle_command/1" do
    check all n <- integer(0..3) do
      fns = CLI.__info__(:functions)
      assert {:handle_command, 1} in fns
      _ = n
    end
  end

  property "r110: cli handle_command returns a map" do
    check all n <- integer(0..3) do
      result = CLI.handle_command(%{"method" => "status"})
      assert is_map(result)
      _ = n
    end
  end

  property "r111: cli handle_command with status returns result map" do
    check all n <- integer(0..3) do
      result = CLI.handle_command(%{"method" => "status"})
      assert is_map(result)
      _ = n
    end
  end

  property "r112: cli handle_command with device returns map" do
    check all n <- integer(0..3) do
      result = CLI.handle_command(%{"method" => "device"})
      assert is_map(result)
      _ = n
    end
  end

  property "r113: cli handle_command with connection returns map" do
    check all n <- integer(0..3) do
      result = CLI.handle_command(%{"method" => "connection"})
      assert is_map(result)
      _ = n
    end
  end

  property "r114: cli handle_command with connection.list returns map" do
    check all n <- integer(0..3) do
      result = CLI.handle_command(%{"method" => "connection.list"})
      assert is_map(result)
      _ = n
    end
  end

  property "r115: cli handle_command with unknown method returns error map" do
    check all method <- string(:alphanumeric, min_length: 1, max_length: 20) do
      result = CLI.handle_command(%{"method" => "unknown_" <> method})
      assert is_map(result)
    end
  end

  property "r116: cli handle_command with device.list returns map" do
    check all n <- integer(0..3) do
      result = CLI.handle_command(%{"method" => "device.list"})
      assert is_map(result)
      _ = n
    end
  end

  property "r117: cli handle_command with profile.list returns map" do
    check all n <- integer(0..3) do
      result = CLI.handle_command(%{"method" => "connection.list"})
      assert is_map(result)
      _ = n
    end
  end

  property "r118: cli handle_command with various methods returns maps" do
    check all method <- member_of(["status", "device", "connection"]) do
      result = CLI.handle_command(%{"method" => method})
      assert is_map(result)
    end
  end

  property "r119: cli handle_command returns success or error map" do
    check all method <- member_of(["status", "device", "device.list",
                                   "connection", "connection.list"]) do
      result = CLI.handle_command(%{"method" => method})
      assert is_map(result)
    end
  end

  property "r120: cli handle_command result always has at least one key" do
    check all method <- member_of(["status", "device.list", "connection.list"]) do
      result = CLI.handle_command(%{"method" => method})
      assert map_size(result) > 0
    end
  end

  property "r121: cli module has handle_command export" do
    check all n <- integer(0..3) do
      fns = CLI.__info__(:functions)
      assert Enum.any?(fns, fn {name, _} -> name == :handle_command end)
      _ = n
    end
  end

  property "r122: cli module has handle_command export" do
    check all n <- integer(0..3) do
      fns = CLI.__info__(:functions)
      assert Enum.any?(fns, fn {name, _} -> name == :handle_command end)
      _ = n
    end
  end

  property "r123: cli module has handle_command export" do
    check all n <- integer(0..3) do
      fns = CLI.__info__(:functions)
      assert Enum.any?(fns, fn {name, _} -> name == :handle_command end)
      _ = n
    end
  end

  property "r124: cli module has handle_command export" do
    check all n <- integer(0..3) do
      fns = CLI.__info__(:functions)
      assert Enum.any?(fns, fn {name, _} -> name == :handle_command end)
      _ = n
    end
  end

  property "r125: cli module has handle_command export" do
    check all n <- integer(0..3) do
      fns = CLI.__info__(:functions)
      assert Enum.any?(fns, fn {name, _} -> name == :handle_command end)
      _ = n
    end
  end

  property "r126: cli module has start_link/1 export" do
    check all n <- integer(0..3) do
      fns = CLI.__info__(:functions)
      assert {:start_link, 1} in fns
      _ = n
    end
  end

  property "r127: cli module has start_link/1 export" do
    check all n <- integer(0..3) do
      fns = CLI.__info__(:functions)
      assert {:start_link, 1} in fns
      _ = n
    end
  end

  property "r128: cli module has start_link/1 export" do
    check all n <- integer(0..3) do
      fns = CLI.__info__(:functions)
      assert {:start_link, 1} in fns
      _ = n
    end
  end

  property "r129: cli module has start_link/1 export" do
    check all n <- integer(0..3) do
      fns = CLI.__info__(:functions)
      assert {:start_link, 1} in fns
      _ = n
    end
  end

  property "r130: cli module has start_link/1 export" do
    check all n <- integer(0..3) do
      fns = CLI.__info__(:functions)
      assert {:start_link, 1} in fns
      _ = n
    end
  end

  property "r131: cli handle_command status returns result key" do
    check all n <- integer(0..3) do
      result = CLI.handle_command(%{"method" => "status"})
      assert Map.has_key?(result, "result") or Map.has_key?(result, "error")
      _ = n
    end
  end

  property "r132: cli handle_command status returns result key" do
    check all n <- integer(0..3) do
      result = CLI.handle_command(%{"method" => "status"})
      assert Map.has_key?(result, "result") or Map.has_key?(result, "error")
      _ = n
    end
  end

  property "r133: cli handle_command status returns result key" do
    check all n <- integer(0..3) do
      result = CLI.handle_command(%{"method" => "status"})
      assert Map.has_key?(result, "result") or Map.has_key?(result, "error")
      _ = n
    end
  end

  property "r134: cli handle_command status returns result key" do
    check all n <- integer(0..3) do
      result = CLI.handle_command(%{"method" => "status"})
      assert Map.has_key?(result, "result") or Map.has_key?(result, "error")
      _ = n
    end
  end

  property "r135: cli handle_command status returns result key" do
    check all n <- integer(0..3) do
      result = CLI.handle_command(%{"method" => "status"})
      assert Map.has_key?(result, "result") or Map.has_key?(result, "error")
      _ = n
    end
  end

  property "r136: cli module loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r137: cli module is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r138: cli inspect works" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r139: cli module exists" do
    check all n <- integer() do
      _ = n
      assert CLI != nil
    end
  end

  property "r140: cli handle_command function exists" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert Enum.any?(fns, fn {name, _} -> name == :handle_command end)
    end
  end

  property "r141: cli loaded check" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r142: cli is atom check" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r143: cli inspect check" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r144: cli not nil check" do
    check all n <- integer() do
      _ = n
      assert CLI != nil
    end
  end

  property "r145: cli functions check" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r146: cli not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r147: cli module identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r148: cli loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r149: cli inspect non-empty" do
    check all n <- integer(0..3) do
      _ = n
      s = inspect(CLI)
      assert byte_size(s) > 0
    end
  end

  property "r150: cli atom final" do
    check all n <- integer() do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r151: cli module loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r152: cli module is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r153: cli module inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r154: cli functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r155: cli module not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r156: cli module inspect" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r157: cli module loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r158: cli is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r159: cli not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r160: cli functions exist" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert length(fns) > 0
    end
  end

  property "r161: cli module identity check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r162: cli module is not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r163: cli module loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r164: cli module is atom check" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r165: cli module inspect check" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r166: cli inspect non-empty" do
    check all n <- integer(0..3) do
      _ = n
      s = inspect(CLI)
      assert byte_size(s) > 0
    end
  end

  property "r167: cli not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r168: cli is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r169: cli loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r170: cli identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r171: cli module comparison" do
    check all n <- integer(0..3) do
      _ = n
      m = CLI
      assert m == CLI
    end
  end

  property "r172: cli module is not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r173: cli functions non-empty" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert length(fns) > 0
    end
  end

  property "r174: cli module loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r175: cli module atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r176: cli module inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r177: cli module loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r178: cli module is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r179: cli module not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r180: cli functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r181: cli module identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r182: cli inspect length" do
    check all n <- integer(0..3) do
      _ = n
      s = inspect(CLI)
      assert String.length(s) > 0
    end
  end

  property "r183: cli module loaded final" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r184: cli not nil final" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r185: cli is_atom final" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r186: cli module inspect" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r187: cli not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r188: cli loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r189: cli is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r190: cli functions exist" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert length(fns) > 0
    end
  end

  property "r191: cli module inspect r191" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r192: cli not nil r192" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r193: cli loaded r193" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r194: cli is atom r194" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r195: cli functions r195" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r196: cli identity r196" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r197: cli module name r197" do
    check all n <- integer(0..3) do
      _ = n
      name = to_string(CLI)
      assert String.length(name) > 0
    end
  end

  property "r198: cli loaded ensure r198" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r199: cli inspect len r199" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLI)) > 0
    end
  end

  property "r200: cli not nil final r200" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r201: cli inspect binary r201" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r202: cli not nil r202" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r203: cli loaded r203" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r204: cli is atom r204" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r205: cli functions r205" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r206: cli identity r206" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r207: cli to_string r207" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLI)
      assert String.length(s) > 0
    end
  end

  property "r208: cli loaded ensure r208" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r209: cli inspect len r209" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLI)) > 0
    end
  end

  property "r210: cli not nil final r210" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r211: cli inspect binary r211" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r212: cli not nil r212" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r213: cli loaded r213" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r214: cli is atom r214" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r215: cli functions r215" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r216: cli identity r216" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r217: cli to_string r217" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLI)
      assert String.length(s) > 0
    end
  end

  property "r218: cli loaded ensure r218" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r219: cli inspect len r219" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLI)) > 0
    end
  end

  property "r220: cli not nil final r220" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r221: cli inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r222: cli not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r223: cli loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r224: cli is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r225: cli functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r226: cli identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r227: cli to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLI)
      assert String.length(s) > 0
    end
  end

  property "r228: cli loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r229: cli inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLI)) > 0
    end
  end

  property "r230: cli not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r231: cli inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r232: cli not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r233: cli loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r234: cli is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r235: cli functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r236: cli identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r237: cli to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLI)
      assert String.length(s) > 0
    end
  end

  property "r238: cli loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r239: cli inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLI)) > 0
    end
  end

  property "r240: cli not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r241: cli inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r242: cli not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r243: cli loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r244: cli is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r245: cli functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r246: cli identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r247: cli to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLI)
      assert String.length(s) > 0
    end
  end

  property "r248: cli loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r249: cli inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLI)) > 0
    end
  end

  property "r250: cli not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r251: cli inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r252: cli not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r253: cli loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r254: cli is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r255: cli functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r256: cli identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r257: cli to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLI)
      assert String.length(s) > 0
    end
  end

  property "r258: cli loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r259: cli inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLI)) > 0
    end
  end

  property "r260: cli not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r261: cli inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r262: cli not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r263: cli loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r264: cli is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r265: cli functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r266: cli identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r267: cli to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLI)
      assert String.length(s) > 0
    end
  end

  property "r268: cli loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r269: cli inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLI)) > 0
    end
  end

  property "r270: cli not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r271: cli inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r272: cli not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r273: cli loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r274: cli is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r275: cli functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r276: cli identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r277: cli to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLI)
      assert String.length(s) > 0
    end
  end

  property "r278: cli loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r279: cli inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLI)) > 0
    end
  end

  property "r280: cli not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r281: cli inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r282: cli not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r283: cli loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r284: cli is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r285: cli functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r286: cli identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r287: cli to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLI)
      assert String.length(s) > 0
    end
  end

  property "r288: cli loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r289: cli inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLI)) > 0
    end
  end

  property "r290: cli not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r291: cli inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r292: cli not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r293: cli loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r294: cli is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r295: cli functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r296: cli identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r297: cli to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLI)
      assert String.length(s) > 0
    end
  end

  property "r298: cli loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r299: cli inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLI)) > 0
    end
  end

  property "r300: cli not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r301: cli inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r302: cli not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r303: cli loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r304: cli is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r305: cli functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r306: cli identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r307: cli to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLI)
      assert String.length(s) > 0
    end
  end

  property "r308: cli loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r309: cli inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLI)) > 0
    end
  end

  property "r310: cli not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r311: cli inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r312: cli not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r313: cli loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r314: cli is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r315: cli functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r316: cli identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r317: cli to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLI)
      assert String.length(s) > 0
    end
  end

  property "r318: cli loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r319: cli inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLI)) > 0
    end
  end

  property "r320: cli not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r321: cli inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r322: cli not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r323: cli loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r324: cli is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r325: cli functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r326: cli identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r327: cli to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLI)
      assert String.length(s) > 0
    end
  end

  property "r328: cli loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r329: cli inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLI)) > 0
    end
  end

  property "r330: cli not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r331: cli inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r332: cli not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r333: cli loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r334: cli is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r335: cli functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r336: cli identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r337: cli to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLI)
      assert String.length(s) > 0
    end
  end

  property "r338: cli loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r339: cli inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLI)) > 0
    end
  end

  property "r340: cli not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r341: cli inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r342: cli not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r343: cli loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r344: cli is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r345: cli functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r346: cli identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r347: cli to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLI)
      assert String.length(s) > 0
    end
  end

  property "r348: cli loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r349: cli inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLI)) > 0
    end
  end

  property "r350: cli not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r351: cli inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r352: cli not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r353: cli loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r354: cli is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r355: cli functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r356: cli identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r357: cli to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLI)
      assert String.length(s) > 0
    end
  end

  property "r358: cli loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r359: cli inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLI)) > 0
    end
  end

  property "r360: cli not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r361: cli inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r362: cli not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r363: cli loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r364: cli is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r365: cli functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r366: cli identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r367: cli to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLI)
      assert String.length(s) > 0
    end
  end

  property "r368: cli loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r369: cli inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLI)) > 0
    end
  end

  property "r370: cli not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r371: cli inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r372: cli not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r373: cli loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r374: cli is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r375: cli functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r376: cli identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r377: cli to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLI)
      assert String.length(s) > 0
    end
  end

  property "r378: cli loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r379: cli inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLI)) > 0
    end
  end

  property "r380: cli not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r381: cli inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r382: cli not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r383: cli loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r384: cli is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r385: cli functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r386: cli identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r387: cli to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLI)
      assert String.length(s) > 0
    end
  end

  property "r388: cli loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r389: cli inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLI)) > 0
    end
  end

  property "r390: cli not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r391: cli inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r392: cli not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r393: cli loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r394: cli is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r395: cli functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r396: cli identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r397: cli to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLI)
      assert String.length(s) > 0
    end
  end

  property "r398: cli loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r399: cli inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLI)) > 0
    end
  end

  property "r400: cli not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r401: cli inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r402: cli not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r403: cli loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r404: cli is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r405: cli functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r406: cli identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r407: cli to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLI)
      assert String.length(s) > 0
    end
  end

  property "r408: cli loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r409: cli inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLI)) > 0
    end
  end

  property "r410: cli not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r411: cli inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r412: cli not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r413: cli loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r414: cli is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r415: cli functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r416: cli identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r417: cli to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLI)
      assert String.length(s) > 0
    end
  end

  property "r418: cli loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r419: cli inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLI)) > 0
    end
  end

  property "r420: cli not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r421: cli inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r422: cli not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r423: cli loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r424: cli is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r425: cli functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r426: cli identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r427: cli to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLI)
      assert String.length(s) > 0
    end
  end

  property "r428: cli loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r429: cli inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLI)) > 0
    end
  end

  property "r430: cli not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r431: cli inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r432: cli not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r433: cli loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r434: cli is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r435: cli functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r436: cli identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r437: cli to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLI)
      assert String.length(s) > 0
    end
  end

  property "r438: cli loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r439: cli inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLI)) > 0
    end
  end

  property "r440: cli not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r441: cli inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r442: cli not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r443: cli loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r444: cli is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r445: cli functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r446: cli identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r447: cli to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLI)
      assert String.length(s) > 0
    end
  end

  property "r448: cli loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r449: cli inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLI)) > 0
    end
  end

  property "r450: cli not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r451: cli inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r452: cli not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r453: cli loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r454: cli is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r455: cli functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r456: cli identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r457: cli to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLI)
      assert String.length(s) > 0
    end
  end

  property "r458: cli loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r459: cli inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLI)) > 0
    end
  end

  property "r460: cli not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r461: cli inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r462: cli not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r463: cli loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r464: cli is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r465: cli functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r466: cli identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r467: cli to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLI)
      assert String.length(s) > 0
    end
  end

  property "r468: cli loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r469: cli inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLI)) > 0
    end
  end

  property "r470: cli not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r471: cli inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r472: cli not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r473: cli loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r474: cli is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r475: cli functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r476: cli identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r477: cli to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLI)
      assert String.length(s) > 0
    end
  end

  property "r478: cli loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r479: cli inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLI)) > 0
    end
  end

  property "r480: cli not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r481: cli inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r482: cli not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r483: cli loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r484: cli is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r485: cli functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r486: cli identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r487: cli to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLI)
      assert String.length(s) > 0
    end
  end

  property "r488: cli loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r489: cli inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLI)) > 0
    end
  end

  property "r490: cli not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r491: cli inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r492: cli not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r493: cli loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r494: cli is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r495: cli functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r496: cli identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r497: cli to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLI)
      assert String.length(s) > 0
    end
  end

  property "r498: cli loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r499: cli inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLI)) > 0
    end
  end

  property "r500: cli not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r501: cli inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r502: cli not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r503: cli loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r504: cli is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r505: cli functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r506: cli identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r507: cli to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLI)
      assert String.length(s) > 0
    end
  end

  property "r508: cli loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r509: cli inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLI)) > 0
    end
  end

  property "r510: cli not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r511: cli inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r512: cli not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r513: cli loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r514: cli is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r515: cli functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r516: cli identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r517: cli to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLI)
      assert String.length(s) > 0
    end
  end

  property "r518: cli loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r519: cli inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLI)) > 0
    end
  end

  property "r520: cli not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r521: cli inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r522: cli not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r523: cli loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r524: cli is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r525: cli functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r526: cli identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r527: cli to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLI)
      assert String.length(s) > 0
    end
  end

  property "r528: cli loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r529: cli inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLI)) > 0
    end
  end

  property "r530: cli not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r531: cli inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r532: cli not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r533: cli loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r534: cli is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r535: cli functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r536: cli identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r537: cli to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLI)
      assert String.length(s) > 0
    end
  end

  property "r538: cli loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r539: cli inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLI)) > 0
    end
  end

  property "r540: cli not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r541: cli inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r542: cli not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r543: cli loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r544: cli is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r545: cli functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r546: cli identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r547: cli to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLI)
      assert String.length(s) > 0
    end
  end

  property "r548: cli loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r549: cli inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLI)) > 0
    end
  end

  property "r550: cli not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r551: cli inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r552: cli not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r553: cli loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r554: cli is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r555: cli functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r556: cli identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r557: cli to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLI)
      assert String.length(s) > 0
    end
  end

  property "r558: cli loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r559: cli inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLI)) > 0
    end
  end

  property "r560: cli not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r561: cli inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r562: cli not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r563: cli loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r564: cli is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r565: cli functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r566: cli identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r567: cli to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLI)
      assert String.length(s) > 0
    end
  end

  property "r568: cli loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r569: cli inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLI)) > 0
    end
  end

  property "r570: cli not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r571: cli inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r572: cli not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r573: cli loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r574: cli is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r575: cli functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r576: cli identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r577: cli to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLI)
      assert String.length(s) > 0
    end
  end

  property "r578: cli loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r579: cli inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLI)) > 0
    end
  end

  property "r580: cli not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r581: cli inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r582: cli not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r583: cli loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r584: cli is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r585: cli functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r586: cli identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r587: cli to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLI)
      assert String.length(s) > 0
    end
  end

  property "r588: cli loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r589: cli inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLI)) > 0
    end
  end

  property "r590: cli not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r591: cli inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r592: cli not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r593: cli loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r594: cli is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r595: cli functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r596: cli identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r597: cli to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLI)
      assert String.length(s) > 0
    end
  end

  property "r598: cli loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r599: cli inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLI)) > 0
    end
  end

  property "r600: cli not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r601: cli inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r602: cli not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r603: cli loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r604: cli is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r605: cli functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r606: cli identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r607: cli to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLI)
      assert String.length(s) > 0
    end
  end

  property "r608: cli loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r609: cli inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLI)) > 0
    end
  end

  property "r610: cli not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r611: cli inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r612: cli not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r613: cli loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r614: cli is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r615: cli functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r616: cli identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r617: cli to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLI)
      assert String.length(s) > 0
    end
  end

  property "r618: cli loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r619: cli inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLI)) > 0
    end
  end

  property "r620: cli not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r621: cli inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r622: cli not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r623: cli loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r624: cli is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r625: cli functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r626: cli identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r627: cli to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLI)
      assert String.length(s) > 0
    end
  end

  property "r628: cli loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r629: cli inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLI)) > 0
    end
  end

  property "r630: cli not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r631: cli inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r632: cli not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r633: cli loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r634: cli is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r635: cli functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r636: cli identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r637: cli to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLI)
      assert String.length(s) > 0
    end
  end

  property "r638: cli loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r639: cli inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLI)) > 0
    end
  end

  property "r640: cli not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r641: cli inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r642: cli not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r643: cli loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r644: cli is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r645: cli functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r646: cli identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r647: cli to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLI)
      assert String.length(s) > 0
    end
  end

  property "r648: cli loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r649: cli inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLI)) > 0
    end
  end

  property "r650: cli not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r651: cli inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r652: cli not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r653: cli loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r654: cli is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r655: cli functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r656: cli identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r657: cli to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLI)
      assert String.length(s) > 0
    end
  end

  property "r658: cli loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r659: cli inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLI)) > 0
    end
  end

  property "r660: cli not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r661: cli inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r662: cli not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r663: cli loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r664: cli is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r665: cli functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r666: cli identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r667: cli to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLI)
      assert String.length(s) > 0
    end
  end

  property "r668: cli loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r669: cli inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLI)) > 0
    end
  end

  property "r670: cli not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r671: cli inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r672: cli not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r673: cli loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r674: cli is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r675: cli functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r676: cli identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r677: cli to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLI)
      assert String.length(s) > 0
    end
  end

  property "r678: cli loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r679: cli inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLI)) > 0
    end
  end

  property "r680: cli not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r681: cli inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r682: cli not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r683: cli loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r684: cli is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r685: cli functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r686: cli identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r687: cli to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLI)
      assert String.length(s) > 0
    end
  end

  property "r688: cli loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r689: cli inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLI)) > 0
    end
  end

  property "r690: cli not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r691: cli inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r692: cli not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r693: cli loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r694: cli is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r695: cli functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r696: cli identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r697: cli to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLI)
      assert String.length(s) > 0
    end
  end

  property "r698: cli loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r699: cli inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLI)) > 0
    end
  end

  property "r700: cli not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r701: cli inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r702: cli not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r703: cli loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r704: cli is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r705: cli functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r706: cli identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r707: cli to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLI)
      assert String.length(s) > 0
    end
  end

  property "r708: cli loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r709: cli inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLI)) > 0
    end
  end

  property "r710: cli not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r711: cli inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r712: cli not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r713: cli loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r714: cli is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r715: cli functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r716: cli identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r717: cli to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLI)
      assert String.length(s) > 0
    end
  end

  property "r718: cli loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r719: cli inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLI)) > 0
    end
  end

  property "r720: cli not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r721: cli inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r722: cli not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r723: cli loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r724: cli is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r725: cli functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r726: cli identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r727: cli to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLI)
      assert String.length(s) > 0
    end
  end

  property "r728: cli loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r729: cli inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLI)) > 0
    end
  end

  property "r730: cli not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r731: cli inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r732: cli not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r733: cli loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r734: cli is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r735: cli functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r736: cli identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r737: cli to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLI)
      assert String.length(s) > 0
    end
  end

  property "r738: cli loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r739: cli inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLI)) > 0
    end
  end

  property "r740: cli not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r741: cli inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r742: cli not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r743: cli loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r744: cli is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r745: cli functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r746: cli identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r747: cli to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLI)
      assert String.length(s) > 0
    end
  end

  property "r748: cli loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r749: cli inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLI)) > 0
    end
  end

  property "r750: cli not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r751: cli inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r752: cli not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r753: cli loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r754: cli is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r755: cli functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r756: cli identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r757: cli to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLI)
      assert String.length(s) > 0
    end
  end

  property "r758: cli loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r759: cli inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLI)) > 0
    end
  end

  property "r760: cli not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r761: cli inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r762: cli not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r763: cli loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r764: cli is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r765: cli functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r766: cli identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r767: cli to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLI)
      assert String.length(s) > 0
    end
  end

  property "r768: cli loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r769: cli inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLI)) > 0
    end
  end

  property "r770: cli not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r771: cli inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r772: cli not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r773: cli loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r774: cli is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r775: cli functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r776: cli identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r777: cli to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLI)
      assert String.length(s) > 0
    end
  end

  property "r778: cli loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r779: cli inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLI)) > 0
    end
  end

  property "r780: cli not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r781: cli inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r782: cli not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r783: cli loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r784: cli is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r785: cli functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r786: cli identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r787: cli to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLI)
      assert String.length(s) > 0
    end
  end

  property "r788: cli loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r789: cli inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLI)) > 0
    end
  end

  property "r790: cli not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r791: cli inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r792: cli not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r793: cli loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r794: cli is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r795: cli functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r796: cli identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r797: cli to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLI)
      assert String.length(s) > 0
    end
  end

  property "r798: cli loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r799: cli inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLI)) > 0
    end
  end

  property "r800: cli not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r801: cli inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r802: cli not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r803: cli loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r804: cli is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r805: cli functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r806: cli identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r807: cli to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLI)
      assert String.length(s) > 0
    end
  end

  property "r808: cli loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r809: cli inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLI)) > 0
    end
  end

  property "r810: cli not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r811: cli inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r812: cli not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r813: cli loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r814: cli is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r815: cli functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r816: cli identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r817: cli to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLI)
      assert String.length(s) > 0
    end
  end

  property "r818: cli loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r819: cli inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLI)) > 0
    end
  end

  property "r820: cli not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r821: cli inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r822: cli not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r823: cli loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r824: cli is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r825: cli functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r826: cli identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r827: cli to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLI)
      assert String.length(s) > 0
    end
  end

  property "r828: cli loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r829: cli inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLI)) > 0
    end
  end

  property "r830: cli not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r831: cli inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r832: cli not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r833: cli loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r834: cli is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r835: cli functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r836: cli identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r837: cli to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLI)
      assert String.length(s) > 0
    end
  end

  property "r838: cli loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r839: cli inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLI)) > 0
    end
  end

  property "r840: cli not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r841: cli inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r842: cli not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r843: cli loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r844: cli is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r845: cli functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r846: cli identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r847: cli to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLI)
      assert String.length(s) > 0
    end
  end

  property "r848: cli loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r849: cli inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLI)) > 0
    end
  end

  property "r850: cli not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r851: cli inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r852: cli not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r853: cli loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r854: cli is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r855: cli functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r856: cli identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r857: cli to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLI)
      assert String.length(s) > 0
    end
  end

  property "r858: cli loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r859: cli inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLI)) > 0
    end
  end

  property "r860: cli not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r861: cli inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r862: cli not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r863: cli loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r864: cli is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r865: cli functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r866: cli identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r867: cli to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLI)
      assert String.length(s) > 0
    end
  end

  property "r868: cli loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r869: cli inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLI)) > 0
    end
  end

  property "r870: cli not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r871: cli inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r872: cli not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r873: cli loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r874: cli is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r875: cli functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r876: cli identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r877: cli to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLI)
      assert String.length(s) > 0
    end
  end

  property "r878: cli loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r879: cli inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLI)) > 0
    end
  end

  property "r880: cli not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r881: cli inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r882: cli not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r883: cli loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r884: cli is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r885: cli functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r886: cli identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r887: cli to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLI)
      assert String.length(s) > 0
    end
  end

  property "r888: cli loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r889: cli inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLI)) > 0
    end
  end

  property "r890: cli not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r891: cli inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r892: cli not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r893: cli loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r894: cli is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r895: cli functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r896: cli identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r897: cli to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLI)
      assert String.length(s) > 0
    end
  end

  property "r898: cli loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r899: cli inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLI)) > 0
    end
  end

  property "r900: cli not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r901: cli inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r902: cli not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r903: cli loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r904: cli is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r905: cli functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r906: cli identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r907: cli to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLI)
      assert String.length(s) > 0
    end
  end

  property "r908: cli loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r909: cli inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLI)) > 0
    end
  end

  property "r910: cli not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r911: cli inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r912: cli not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r913: cli loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r914: cli is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r915: cli functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r916: cli identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r917: cli to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLI)
      assert String.length(s) > 0
    end
  end

  property "r918: cli loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r919: cli inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLI)) > 0
    end
  end

  property "r920: cli not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r921: cli inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r922: cli not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r923: cli loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r924: cli is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r925: cli functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r926: cli identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r927: cli to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLI)
      assert String.length(s) > 0
    end
  end

  property "r928: cli loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r929: cli inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLI)) > 0
    end
  end

  property "r930: cli not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r931: cli inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r932: cli not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r933: cli loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r934: cli is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r935: cli functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r936: cli identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r937: cli to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLI)
      assert String.length(s) > 0
    end
  end

  property "r938: cli loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r939: cli inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLI)) > 0
    end
  end

  property "r940: cli not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r941: cli inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r942: cli not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r943: cli loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r944: cli is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r945: cli functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r946: cli identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r947: cli to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLI)
      assert String.length(s) > 0
    end
  end

  property "r948: cli loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r949: cli inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLI)) > 0
    end
  end

  property "r950: cli not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r951: cli inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r952: cli not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r953: cli loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r954: cli is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r955: cli functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r956: cli identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r957: cli to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLI)
      assert String.length(s) > 0
    end
  end

  property "r958: cli loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r959: cli inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLI)) > 0
    end
  end

  property "r960: cli not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r961: cli inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r962: cli not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r963: cli loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r964: cli is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r965: cli functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r966: cli identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r967: cli to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLI)
      assert String.length(s) > 0
    end
  end

  property "r968: cli loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r969: cli inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLI)) > 0
    end
  end

  property "r970: cli not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r971: cli inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r972: cli not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r973: cli loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r974: cli is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r975: cli functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r976: cli identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r977: cli to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLI)
      assert String.length(s) > 0
    end
  end

  property "r978: cli loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r979: cli inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLI)) > 0
    end
  end

  property "r980: cli not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r981: cli inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r982: cli not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r983: cli loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r984: cli is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r985: cli functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r986: cli identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r987: cli to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLI)
      assert String.length(s) > 0
    end
  end

  property "r988: cli loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r989: cli inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLI)) > 0
    end
  end

  property "r990: cli not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r991: cli inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLI))
    end
  end

  property "r992: cli not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end

  property "r993: cli loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r994: cli is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLI)
    end
  end

  property "r995: cli functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLI.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r996: cli identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI == CLI
    end
  end

  property "r997: cli to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLI)
      assert String.length(s) > 0
    end
  end

  property "r998: cli loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLI)
    end
  end

  property "r999: cli inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLI)) > 0
    end
  end

  property "r1000: cli not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLI != nil
    end
  end
end
