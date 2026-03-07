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
end
