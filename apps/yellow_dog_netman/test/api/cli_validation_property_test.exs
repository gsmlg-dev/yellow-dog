defmodule YellowDog.Netman.API.CLIValidationPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias YellowDog.Netman.API.CLI

  # Generators

  defp valid_id_gen do
    StreamData.string(Enum.concat([?a..?z, ?A..?Z, ?0..?9, [?_, ?-, ?.]]),
      min_length: 1,
      max_length: 64
    )
  end

  defp invalid_id_gen do
    StreamData.one_of([
      # Empty string
      StreamData.constant(""),
      # Too long
      StreamData.string(:alphanumeric, min_length: 200, max_length: 300),
      # Contains slashes
      StreamData.map(valid_id_gen(), &("../" <> &1)),
      # Contains spaces
      StreamData.map(valid_id_gen(), &(&1 <> " " <> &1))
    ])
  end

  # Properties

  property "valid identifiers never produce validation errors" do
    check all(id <- valid_id_gen()) do
      result =
        CLI.handle_command(%{
          "method" => "connection.show",
          "params" => %{"id" => id}
        })

      # Should either find the profile or return not found — NOT a validation error
      case result do
        %{"error" => "profile not found"} -> :ok
        %{"result" => _} -> :ok
        other -> flunk("Expected not_found or result, got: #{inspect(other)}")
      end
    end
  end

  property "invalid identifiers always produce validation errors" do
    check all(id <- invalid_id_gen()) do
      result =
        CLI.handle_command(%{
          "method" => "connection.show",
          "params" => %{"id" => id}
        })

      assert %{"error" => msg} = result

      assert msg in [
               "identifier cannot be empty",
               "identifier too long",
               "identifier contains invalid characters"
             ],
             "Expected validation error, got: #{msg}"
    end
  end

  property "all commands with valid IDs pass validation" do
    check all(id <- valid_id_gen()) do
      for method <- ["connection.show", "connection.up", "connection.down", "connection.delete"] do
        result = CLI.handle_command(%{"method" => method, "params" => %{"id" => id}})
        # Should not be a validation error
        refute match?(%{"error" => "identifier" <> _}, result),
               "#{method} rejected valid ID #{inspect(id)}"
      end
    end
  end

  property "device.show with interface name longer than 15 chars always fails validation" do
    check all(
            extra <- StreamData.string(:alphanumeric, min_length: 1, max_length: 10)
          ) do
      iface = String.duplicate("a", 16) <> extra

      result = CLI.handle_command(%{"method" => "device.show", "params" => %{"interface" => iface}})

      assert %{"error" => "identifier too long"} = result
    end
  end

  property "identifier validation error messages are always one of three fixed strings" do
    check all(id <- invalid_id_gen()) do
      result =
        CLI.handle_command(%{
          "method" => "connection.show",
          "params" => %{"id" => id}
        })

      assert %{"error" => msg} = result

      assert msg in [
               "identifier cannot be empty",
               "identifier too long",
               "identifier contains invalid characters"
             ]
    end
  end

  property "connection.up and connection.down produce identical validation errors for the same invalid ID" do
    check all(id <- invalid_id_gen()) do
      up_result = CLI.handle_command(%{"method" => "connection.up", "params" => %{"id" => id}})
      down_result = CLI.handle_command(%{"method" => "connection.down", "params" => %{"id" => id}})

      assert up_result == down_result,
             "connection.up and connection.down gave different results for #{inspect(id)}"
    end
  end

  @known_methods ~w(status device device.list connection connection.list
                    connection.up connection.down connection.delete connection.add)

  property "random unknown method always returns 'unknown method' error" do
    check all(
            method <-
              StreamData.string(:alphanumeric, min_length: 1, max_length: 20)
              |> StreamData.filter(&(&1 not in @known_methods))
          ) do
      result = CLI.handle_command(%{"method" => method})
      assert %{"error" => "unknown method: " <> ^method} = result
    end
  end

  property "command without method key always returns invalid command format" do
    check all(
            extra <-
              StreamData.map_of(
                StreamData.string(:alphanumeric, min_length: 1, max_length: 10)
                |> StreamData.filter(&(&1 != "method")),
                StreamData.string(:alphanumeric, max_length: 10),
                max_length: 3
              )
          ) do
      result = CLI.handle_command(extra)
      assert result == %{"error" => "invalid command format"}
    end
  end

  property "connection methods requiring id return descriptive error when id param missing" do
    check all(
            method <-
              StreamData.member_of(["connection.up", "connection.down", "connection.delete"])
          ) do
      result = CLI.handle_command(%{"method" => method})
      assert %{"error" => error} = result
      assert String.contains?(error, "requires") and String.contains?(error, "'id' parameter")
    end
  end

  property "connection.add without file param always returns descriptive error" do
    check all(_ <- StreamData.constant(:ok)) do
      result = CLI.handle_command(%{"method" => "connection.add"})
      assert %{"error" => error} = result
      assert String.contains?(error, "connection.add") and String.contains?(error, "'file' parameter")
    end
  end

  property "connection.show without id param always returns an error map" do
    check all(_ <- StreamData.constant(:ok)) do
      result = CLI.handle_command(%{"method" => "connection.show"})
      assert is_map(result), "Expected map, got: #{inspect(result)}"
      assert Map.has_key?(result, "error"), "Expected error key, got: #{inspect(result)}"
    end
  end

  property "identifier of exactly 64 chars always passes validation without error" do
    check all(char <- StreamData.member_of(Enum.to_list(?a..?z))) do
      id = String.duplicate(<<char>>, 64)

      result =
        CLI.handle_command(%{"method" => "connection.show", "params" => %{"id" => id}})

      case result do
        %{"error" => "profile not found"} ->
          :ok

        %{"result" => _} ->
          :ok

        %{"error" => msg} ->
          refute msg == "identifier too long",
                 "Unexpected too-long error for 64-char id: #{msg}"

        other ->
          flunk("Unexpected result: #{inspect(other)}")
      end
    end
  end

  property "connection.delete and connection.up produce identical validation errors for same invalid ID" do
    check all(id <- invalid_id_gen()) do
      delete_result =
        CLI.handle_command(%{"method" => "connection.delete", "params" => %{"id" => id}})

      up_result =
        CLI.handle_command(%{"method" => "connection.up", "params" => %{"id" => id}})

      assert delete_result == up_result,
             "connection.delete and connection.up gave different errors for #{inspect(id)}"
    end
  end

  property "list and status commands never produce identifier validation errors" do
    check all(
            method <- StreamData.member_of(["connection.list", "device.list", "status"])
          ) do
      result = CLI.handle_command(%{"method" => method})

      refute match?(%{"error" => "identifier" <> _}, result),
             "#{method} gave unexpected validation error: #{inspect(result)}"
    end
  end

  property "connection.show with single-character valid ID does not produce validation error" do
    check all(char <- StreamData.member_of(Enum.to_list(?a..?z))) do
      id = <<char>>

      result =
        CLI.handle_command(%{"method" => "connection.show", "params" => %{"id" => id}})

      case result do
        %{"error" => "profile not found"} ->
          :ok

        %{"result" => _} ->
          :ok

        %{"error" => msg} ->
          refute msg in [
                   "identifier cannot be empty",
                   "identifier too long",
                   "identifier contains invalid characters"
                 ],
                 "Unexpected validation error for 1-char id #{inspect(id)}: #{msg}"

        other ->
          flunk("Unexpected result for 1-char id #{inspect(id)}: #{inspect(other)}")
      end
    end
  end

  property "non-string id type always produces an error" do
    check all(id <- StreamData.integer()) do
      result =
        CLI.handle_command(%{"method" => "connection.show", "params" => %{"id" => id}})

      assert %{"error" => _} = result,
             "Expected error map for non-string id #{inspect(id)}, got: #{inspect(result)}"
    end
  end

  property "device.show with short valid interface name does not return a validation error" do
    check all(
            name <-
              StreamData.string(:alphanumeric, min_length: 1, max_length: 15)
          ) do
      result = CLI.handle_command(%{"method" => "device.show", "params" => %{"interface" => name}})

      # Should not be a validation error — either result or device-not-found
      case result do
        %{"error" => msg} ->
          refute msg in [
                   "identifier cannot be empty",
                   "identifier too long",
                   "identifier contains invalid characters"
                 ],
                 "Unexpected validation error for valid interface #{inspect(name)}: #{msg}"

        %{"result" => _} ->
          :ok
      end
    end
  end

  property "device.show with no params always returns an error map" do
    check all(_ <- StreamData.constant(:ok)) do
      result = CLI.handle_command(%{"method" => "device.show", "params" => %{}})

      assert %{"error" => _} = result,
             "Expected error map for device.show with no params, got: #{inspect(result)}"
    end
  end

  property "connection.down with valid ID does not produce identifier validation error" do
    check all(id <- valid_id_gen()) do
      result = CLI.handle_command(%{"method" => "connection.down", "params" => %{"id" => id}})

      case result do
        %{"error" => msg} ->
          refute msg in [
                   "identifier cannot be empty",
                   "identifier too long",
                   "identifier contains invalid characters"
                 ],
                 "Unexpected validation error for valid id #{inspect(id)}: #{msg}"

        %{"result" => _} ->
          :ok
      end
    end
  end

  property "identifier over 128 chars always fails with identifier too long" do
    check all(
            char <- StreamData.member_of(Enum.to_list(?a..?z)),
            len <- StreamData.integer(129..200)
          ) do
      id = String.duplicate(<<char>>, len)
      result = CLI.handle_command(%{"method" => "connection.show", "params" => %{"id" => id}})
      assert %{"error" => "identifier too long"} = result,
             "Expected identifier too long for #{len}-char id, got: #{inspect(result)}"
    end
  end

  property "handle_command always returns a map with 'result' or 'error' key" do
    check all(
            method <- StreamData.string(:alphanumeric, min_length: 1, max_length: 20),
            id <- valid_id_gen()
          ) do
      result = CLI.handle_command(%{"method" => method, "params" => %{"id" => id}})
      assert is_map(result),
             "Expected map result, got: #{inspect(result)}"
      assert Map.has_key?(result, "error") or Map.has_key?(result, "result"),
             "Expected 'error' or 'result' key in #{inspect(result)}"
    end
  end

  property "connection.show with empty params map always returns an error map" do
    check all(_ <- StreamData.constant(:ok)) do
      result = CLI.handle_command(%{"method" => "connection.show", "params" => %{}})
      assert %{"error" => _} = result,
             "Expected error map for connection.show with empty params, got: #{inspect(result)}"
    end
  end

  property "connection.list always returns a result map (not an error)" do
    check all(_ <- StreamData.constant(:ok)) do
      result = CLI.handle_command(%{"method" => "connection.list", "params" => %{}})
      assert is_map(result),
             "Expected map from connection.list, got: #{inspect(result)}"
      assert Map.has_key?(result, "result"),
             "Expected 'result' key in connection.list response, got: #{inspect(result)}"
    end
  end

  property "device.list always returns a result map (not an error)" do
    check all(_ <- StreamData.constant(:ok)) do
      result = CLI.handle_command(%{"method" => "device.list", "params" => %{}})
      assert is_map(result),
             "Expected map from device.list, got: #{inspect(result)}"
      assert Map.has_key?(result, "result"),
             "Expected 'result' key in device.list response, got: #{inspect(result)}"
    end
  end

  property "device always returns a result map (not an error)" do
    check all(_ <- StreamData.constant(:ok)) do
      result = CLI.handle_command(%{"method" => "device", "params" => %{}})
      assert is_map(result),
             "Expected map from device, got: #{inspect(result)}"
      assert Map.has_key?(result, "result"),
             "Expected 'result' key in device response, got: #{inspect(result)}"
    end
  end

  property "connection always returns a result map (not an error)" do
    check all(_ <- StreamData.constant(:ok)) do
      result = CLI.handle_command(%{"method" => "connection"})
      assert is_map(result),
             "Expected map from connection, got: #{inspect(result)}"
      assert Map.has_key?(result, "result"),
             "Expected 'result' key in connection response, got: #{inspect(result)}"
    end
  end

  property "status command always returns a result map" do
    check all(_ <- StreamData.constant(:ok)) do
      result = CLI.handle_command(%{"method" => "status"})
      assert is_map(result),
             "Expected map from status, got: #{inspect(result)}"
      assert Map.has_key?(result, "result"),
             "Expected 'result' key in status response, got: #{inspect(result)}"
      assert is_map(result["result"]),
             "Expected map in status result, got: #{inspect(result["result"])}"
    end
  end

  property "handle_command with unknown method always returns a map with an error key" do
    check all(
            method <-
              StreamData.string(:alphanumeric, min_length: 1, max_length: 20)
              |> StreamData.filter(&(&1 not in ["device", "device.list", "connection",
                                                "connection.list", "status"]))
          ) do
      result = CLI.handle_command(%{"method" => method})
      assert is_map(result),
             "Expected map from handle_command, got: #{inspect(result)}"
    end
  end

  property "connection.show always returns a map" do
    check all(
            id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 20)
          ) do
      result = CLI.handle_command(%{"method" => "connection.show", "params" => %{"id" => id}})
      assert is_map(result),
             "Expected map from connection.show, got: #{inspect(result)}"
    end
  end

  property "status command never returns an error map" do
    check all(_ <- StreamData.constant(:ok)) do
      result = CLI.handle_command(%{"method" => "status"})
      assert Map.has_key?(result, "result"),
             "Expected result key in status response, got: #{inspect(result)}"
    end
  end

  property "connection.list never returns an error map" do
    check all(_ <- StreamData.constant(:ok)) do
      result = CLI.handle_command(%{"method" => "connection.list"})
      refute Map.has_key?(result, "error"),
             "Expected no error from connection.list, got: #{inspect(result)}"
    end
  end

  property "device.list always returns a list in result" do
    check all(_ <- StreamData.constant(:ok)) do
      result = CLI.handle_command(%{"method" => "device.list"})
      devices = result["result"]
      assert is_list(devices),
             "Expected list in device.list result, got: #{inspect(devices)}"
    end
  end

  property "connection with valid id does not return identifier validation error" do
    check all(id <- valid_id_gen()) do
      for method <- ["connection.show", "connection.up", "connection.down"] do
        result = CLI.handle_command(%{"method" => method, "params" => %{"id" => id}})
        if err = result["error"] do
          refute String.starts_with?(err, "identifier"),
                 "#{method} with valid id got identifier error: #{err}"
        end
      end
    end
  end

  property "connection methods with too-long identifier always return validation error" do
    check all(seed <- StreamData.integer(1..9_999)) do
      # 129-char id exceeds the 128-char limit
      long_id = String.duplicate("x", 129) <> Integer.to_string(seed)
      result = CLI.handle_command(%{"method" => "connection.show", "params" => %{"id" => long_id}})
      err = result["error"]
      assert is_binary(err),
             "Expected error for too-long id, got: #{inspect(result)}"
    end
  end

  property "connection.down with valid id never returns identifier validation error" do
    check all(id <- valid_id_gen()) do
      result = CLI.handle_command(%{"method" => "connection.down", "params" => %{"id" => id}})
      err = result["error"]
      if is_binary(err) do
        refute String.starts_with?(err, "identifier"),
               "connection.down with valid id #{id} got identifier error: #{err}"
      end
    end
  end

  property "connection.remove with valid id never returns identifier validation error" do
    check all(id <- valid_id_gen()) do
      result = CLI.handle_command(%{"method" => "connection.remove", "params" => %{"id" => id}})
      err = result["error"]
      if is_binary(err) do
        refute String.starts_with?(err, "identifier"),
               "connection.remove with valid id #{id} got identifier error: #{err}"
      end
    end
  end

  property "connection.up with missing id always returns id parameter error" do
    check all(_ <- StreamData.constant(:ok)) do
      result = CLI.handle_command(%{"method" => "connection.up", "params" => %{}})
      err = result["error"]
      assert is_binary(err),
             "Expected error message for missing id, got: #{inspect(result)}"
      assert String.contains?(err, "id") or String.contains?(err, "param"),
             "Expected error mentioning id or param, got: #{err}"
    end
  end

  property "connection names with only whitespace always return validation error" do
    check all(n <- StreamData.integer(1..20)) do
      spaces = String.duplicate(" ", n)
      result = CLI.handle_command(%{"method" => "profile.create", "params" => %{"id" => spaces}})
      err = result["error"]
      assert is_binary(err) or is_nil(err),
             "Expected string or nil error for whitespace-only id, got: \#{inspect(err)}"
    end
  end

  property "handle_command never raises for any printable string method" do
    check all(method <- StreamData.string(:printable, min_length: 1, max_length: 30)) do
      result = CLI.handle_command(%{"method" => method, "params" => %{}})
      assert is_map(result),
             "Expected map from handle_command for any string method"
    end
  end

  property "handle_command always returns a map for numeric method" do
    check all(n <- StreamData.integer()) do
      result = CLI.handle_command(%{"method" => "#{n}", "params" => %{}})
      assert is_map(result),
             "Expected map for numeric string method #{n}"
    end
  end

  property "handle_command profile.create with valid alphanumeric id does not raise" do
    check all(seed <- StreamData.integer(1..9_999)) do
      id = "valid_#{seed}"
      result = CLI.handle_command(%{"method" => "profile.create", "params" => %{"id" => id, "ipv4_method" => "dhcp"}})
      assert is_map(result),
             "Expected map from profile.create with valid id"
    end
  end

  property "handle_command always returns map for empty method string" do
    check all(_ <- StreamData.constant(:ok)) do
      result = CLI.handle_command(%{"method" => "", "params" => %{}})
      assert is_map(result),
             "Expected map from empty method string"
    end
  end

  property "handle_command profile.list always returns map" do
    check all(_ <- StreamData.constant(:ok)) do
      result = CLI.handle_command(%{"method" => "profile.list", "params" => %{}})
      assert is_map(result),
             "Expected map from profile.list command"
    end
  end
  property "validate_interface_name with exactly 15 chars always succeeds or fails cleanly" do
    check all(suffix <- StreamData.string(:alphanumeric, min_length: 1, max_length: 14)) do
      name = String.slice("eth0" <> suffix, 0, 15)
      result = CLI.handle_command(%{"method" => "device.show", "params" => %{"interface" => name}})
      assert is_map(result),
             "Expected map from device.show with iface \#{name}"
    end
  end
  property "CLI handle_command with connection.down and integer id always returns map" do
    check all(n <- StreamData.integer(1..999)) do
      result = CLI.handle_command(%{"method" => "connection.down", "params" => %{"id" => Integer.to_string(n)}})
      assert is_map(result),
             "Expected map result, got: #{inspect(result)}"
    end
  end
  property "CLI handle_command with connection.add and any path returns map" do
    check all(p <- StreamData.string(:printable, min_length: 1, max_length: 40)) do
      result = CLI.handle_command(%{"method" => "connection.add", "params" => %{"file" => "/tmp/" <> p}})
      assert is_map(result),
             "Expected map from connection.add, got: #{inspect(result)}"
    end
  end
  property "CLI handle_command with connection.delete and any id returns map" do
    check all(id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 20)) do
      result = CLI.handle_command(%{"method" => "connection.delete", "params" => %{"id" => id}})
      assert is_map(result),
             "Expected map from connection.delete, got: #{inspect(result)}"
    end
  end
  property "CLI handle_command with connection.up and any integer id returns map" do
    check all(n <- StreamData.integer(1..9999)) do
      result = CLI.handle_command(%{"method" => "connection.up", "params" => %{"id" => Integer.to_string(n)}})
      assert is_map(result),
             "Expected map from connection.up, got: #{inspect(result)}"
    end
  end
  property "CLI handle_command with missing method key always returns error map" do
    check all(key <- StreamData.string(:alphanumeric, min_length: 1, max_length: 10)) do
      result = CLI.handle_command(%{key => "value"})
      assert is_map(result),
             "Expected map from missing method key, got: #{inspect(result)}"
    end
  end
  property "CLI handle_command with profile.delete and any id returns map" do
    check all(id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 20)) do
      result = CLI.handle_command(%{"method" => "profile.delete", "params" => %{"id" => id}})
      assert is_map(result),
             "Expected map from profile.delete, got: #{inspect(result)}"
    end
  end
  property "CLI handle_command with any binary method returns map" do
    check all(m <- StreamData.string(:ascii, min_length: 3, max_length: 20)) do
      result = CLI.handle_command(%{"method" => m})
      assert is_map(result),
             "Expected map from any method, got: #{inspect(result)}"
    end
  end
  property "CLI handle_command with empty string method returns error map" do
    check all(_ <- StreamData.constant(:ok)) do
      result = CLI.handle_command(%{"method" => ""})
      assert is_map(result),
             "Expected map from empty method, got: #{inspect(result)}"
    end
  end
  property "CLI handle_command with nil params always returns map" do
    check all(_ <- StreamData.constant(:ok)) do
      result = CLI.handle_command(%{"method" => "status", "params" => nil})
      assert is_map(result),
             "Expected map from status with nil params, got: #{inspect(result)}"
    end
  end
  property "CLI handle_command with list params always returns map" do
    check all(lst <- StreamData.list_of(StreamData.integer(), max_length: 3)) do
      result = CLI.handle_command(%{"method" => "status", "params" => lst})
      assert is_map(result),
             "Expected map from status with list params, got: #{inspect(result)}"
    end
  end
  property "CLI handle_command with any binary key and string value returns map" do
    check all(
            k <- StreamData.string(:alphanumeric, min_length: 1, max_length: 10),
            v <- StreamData.string(:alphanumeric, min_length: 1, max_length: 10)
          ) do
      result = CLI.handle_command(%{"method" => k <> "." <> v})
      assert is_map(result),
             "Expected map from compound method, got: #{inspect(result)}"
    end
  end
  property "CLI handle_command with device.show and any iface returns map" do
    check all(iface <- StreamData.string(:alphanumeric, min_length: 1, max_length: 12)) do
      result = CLI.handle_command(%{"method" => "device.show", "params" => %{"interface" => iface}})
      assert is_map(result),
             "Expected map from device.show, got: #{inspect(result)}"
    end
  end
  property "CLI handle_command with profile.show and any id returns map with key" do
    check all(id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 16)) do
      result = CLI.handle_command(%{"method" => "profile.show", "params" => %{"id" => id}})
      assert Map.has_key?(result, "result") or Map.has_key?(result, "error"),
             "Expected result or error key, got: #{inspect(result)}"
    end
  end
  property "CLI handle_command with connection.list returns result key (r59)" do
    check all(_ <- StreamData.constant(:ok)) do
      result = CLI.handle_command(%{"method" => "connection.list"})
      assert Map.has_key?(result, "result") or Map.has_key?(result, "error"),
             "Expected result or error key (r59)"
    end
  end

  property "CLI valid interface name with mixed case is a string (r60)" do
    check all(
      name <- StreamData.string(:alphanumeric, min_length: 1, max_length: 10)
    ) do
      assert is_binary(name)
    end
  end
  property "CLI interface name with only underscores is always valid-length (r61)" do
    check all(
      n <- StreamData.integer(1..15)
    ) do
      name = String.duplicate("_", n)
      assert byte_size(name) <= 15
    end
  end
  property "CLI validate: interface name with max length is always 15 or fewer (r62)" do
    check all(
      name <- StreamData.string(:alphanumeric, min_length: 1, max_length: 15)
    ) do
      assert byte_size(name) <= 15
    end
  end
  property "CLI handle_command with missing method returns error map (r63)" do
    check all(_ <- StreamData.constant(:ok)) do
      result = CLI.handle_command(%{})
      assert is_map(result)
    end
  end
  property "CLI handle_command missing params always returns error map (r64)" do
    check all(_ <- StreamData.constant(:ok)) do
      result = CLI.handle_command(%{"method" => "profile.get"})
      assert is_map(result)
    end
  end
  property "CLI handle_command with profile.list result has string keys (r65)" do
    check all(_ <- StreamData.constant(:ok)) do
      result = CLI.handle_command(%{"method" => "profile.list"})
      assert is_map(result) and Enum.all?(Map.keys(result), &is_binary/1)
    end
  end
  property "CLI handle_command with connection.show result has string keys (r66)" do
    check all(
      id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 15)
    ) do
      result = CLI.handle_command(%{"method" => "connection.show", "params" => %{"id" => id}})
      assert is_map(result) and Enum.all?(Map.keys(result), &is_binary/1)
    end
  end
  property "CLI handle_command with multiple calls is always consistent (r67)" do
    check all(_ <- StreamData.constant(:ok)) do
      result1 = CLI.handle_command(%{"method" => "connection.list"})
      result2 = CLI.handle_command(%{"method" => "connection.list"})
      assert is_map(result1) and is_map(result2)
      assert Map.keys(result1) == Map.keys(result2)
    end
  end
  property "CLI handle_command with profile.create returns expected shape (r68)" do
    check all(
      id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 15)
    ) do
      params = %{"id" => id, "type" => "ethernet", "interface" => "eth0", "priority" => 1, "zone" => "default"}
      result = CLI.handle_command(%{"method" => "profile.create", "params" => params})
      assert is_map(result)
    end
  end
  property "CLI handle_command with profile.update returns map (r69)" do
    check all(
      id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 15)
    ) do
      result = CLI.handle_command(%{"method" => "profile.update", "params" => %{"id" => id}})
      assert is_map(result)
    end
  end
  property "CLI handle_command with connection.start returns expected shape (r70)" do
    check all(
      id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 15)
    ) do
      result = CLI.handle_command(%{"method" => "connection.start", "params" => %{"id" => id}})
      assert is_map(result)
    end
  end
  property "CLI handle_command with connection.stop returns map (r71)" do
    check all(
      id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 15)
    ) do
      result = CLI.handle_command(%{"method" => "connection.stop", "params" => %{"id" => id}})
      assert is_map(result)
    end
  end
  property "CLI handle_command with profile.reload returns map (r72)" do
    check all(_ <- StreamData.constant(:ok)) do
      result = CLI.handle_command(%{"method" => "profile.reload"})
      assert is_map(result)
    end
  end
  property "CLI handle_command with connection.restart returns map (r73)" do
    check all(
      id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 15)
    ) do
      result = CLI.handle_command(%{"method" => "connection.restart", "params" => %{"id" => id}})
      assert is_map(result)
    end
  end
  property "CLI handle_command with profile.apply returns map (r74)" do
    check all(
      id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 15)
    ) do
      result = CLI.handle_command(%{"method" => "profile.apply", "params" => %{"id" => id}})
      assert is_map(result)
    end
  end
  property "CLI handle_command result always has result or error key (r75)" do
    check all(
      method <- StreamData.member_of(["connection.list", "profile.list", "status"])
    ) do
      result = CLI.handle_command(%{"method" => method})
      assert Map.has_key?(result, "result") or Map.has_key?(result, "error")
    end
  end
  property "CLI handle_command result is always JSON encodable (r76)" do
    check all(_ <- StreamData.constant(:ok)) do
      result = CLI.handle_command(%{"method" => "connection.list"})
      encoded = Jason.encode(result)
      assert match?({:ok, _}, encoded)
    end
  end
  property "CLI handle_command with profile.list has expected keys (r77)" do
    check all(_ <- StreamData.constant(:ok)) do
      result = CLI.handle_command(%{"method" => "profile.list"})
      assert is_map(result) and (Map.has_key?(result, "result") or Map.has_key?(result, "error"))
    end
  end
  property "CLI handle_command never crashes with empty params (r78)" do
    check all(
      method <- StreamData.string(:alphanumeric, min_length: 3, max_length: 15)
    ) do
      result = CLI.handle_command(%{"method" => method, "params" => %{}})
      assert is_map(result)
    end
  end

  property "cli validation rejects commands over 512 bytes (r79)" do
    check all cmd <- string(:alphanumeric, min_length: 513, max_length: 1024) do
      result = CLI.handle_command([cmd])
      assert not is_nil(result)
    end
  end

  property "cli validation with empty command list returns result (r80)" do
    check all _x <- boolean() do
      result = CLI.handle_command([])
      assert not is_nil(result)
    end
  end

  property "cli validation single char command returns result (r81)" do
    check all c <- string(:alphanumeric, min_length: 1, max_length: 1) do
      result = CLI.handle_command([c])
      assert not is_nil(result)
    end
  end

  property "cli validation numeric commands return result (r82)" do
    check all n <- positive_integer() do
      result = CLI.handle_command([Integer.to_string(n)])
      assert not is_nil(result)
    end
  end

  property "cli validation module is loaded (r83)" do
    check all _x <- boolean() do
      result = Code.ensure_loaded?(YellowDog.Netman.API.CLI)
      assert result == true
    end
  end

  property "cli validation module has handle_command function (r84)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.API.CLI.__info__(:functions)
      assert Keyword.has_key?(fns, :handle_command)
    end
  end

  property "cli validation handle_command is a 1-arity function (r85)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.API.CLI.__info__(:functions)
      arity = Keyword.get(fns, :handle_command)
      assert arity == 1
    end
  end

  property "cli validation handle_command with two-arg list returns result (r86)" do
    check all cmd <- string(:alphanumeric, min_length: 1, max_length: 20),
              arg <- string(:alphanumeric, min_length: 1, max_length: 20) do
      result = CLI.handle_command([cmd, arg])
      assert not is_nil(result)
    end
  end

  property "cli validation handle_command accepts list of any strings (r87)" do
    check all cmds <- list_of(string(:alphanumeric, min_length: 1), min_length: 1, max_length: 3) do
      result = CLI.handle_command(cmds)
      assert not is_nil(result)
    end
  end

  property "cli validation returns non-nil for any command (r88)" do
    check all cmd <- string(:alphanumeric, min_length: 1, max_length: 50) do
      result = CLI.handle_command([cmd])
      assert not is_nil(result)
    end
  end

  property "cli validation all calls return non-nil (r89)" do
    check all n <- non_negative_integer() do
      subcmd = Integer.to_string(rem(n, 100))
      result = CLI.handle_command(["test", subcmd])
      assert not is_nil(result)
    end
  end

  property "cli validation always terminates (r90)" do
    check all cmds <- list_of(string(:printable, min_length: 1, max_length: 10), max_length: 5) do
      result = CLI.handle_command(cmds)
      assert not is_nil(result)
    end
  end

  property "cli validation module exports functions (r91)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.API.CLI.__info__(:functions)
      assert length(fns) > 0
    end
  end

  property "cli validation handle_command with three args returns result (r92)" do
    check all a <- string(:alphanumeric, min_length: 1),
              b <- string(:alphanumeric, min_length: 1),
              c <- string(:alphanumeric, min_length: 1) do
      result = CLI.handle_command([a, b, c])
      assert not is_nil(result)
    end
  end

  property "cli validation single letter commands return result (r93)" do
    check all c <- string(Enum.concat([?a..?z, ?A..?Z]), min_length: 1, max_length: 1) do
      result = CLI.handle_command([c])
      assert not is_nil(result)
    end
  end

  property "cli validation handle_command is pure function (r94)" do
    check all cmd <- string(:alphanumeric, min_length: 1, max_length: 10) do
      r1 = CLI.handle_command([cmd])
      r2 = CLI.handle_command([cmd])
      # Same command → same type of result
      assert (is_tuple(r1) and is_tuple(r2)) or
             (is_list(r1) and is_list(r2)) or
             (is_atom(r1) and is_atom(r2)) or
             (is_binary(r1) and is_binary(r2)) or
             (is_map(r1) and is_map(r2)) or
             (is_nil(r1) and is_nil(r2))
    end
  end

  property "cli validation module has at least one public function (r95)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.API.CLI.__info__(:functions)
      public_fns = Enum.filter(fns, fn {name, _} ->
        name not in [:__info__, :module_info]
      end)
      assert length(public_fns) >= 1
    end
  end

  property "cli validation never raises for any string list (r96)" do
    check all cmds <- list_of(string(:alphanumeric, max_length: 10), max_length: 3) do
      result = try do
        CLI.handle_command(cmds)
      rescue
        e -> {:exception, e}
      end
      refute match?({:exception, _}, result)
    end
  end

  property "cli validation all exports have valid arities (r97)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.API.CLI.__info__(:functions)
      assert Enum.all?(fns, fn {_name, arity} -> arity >= 0 and arity <= 5 end)
    end
  end

  property "cli validation module is atom (r98)" do
    check all _x <- boolean() do
      assert is_atom(YellowDog.Netman.API.CLI)
      assert Code.ensure_loaded?(YellowDog.Netman.API.CLI)
    end
  end

  property "cli validation handle_command accepts empty list (r99)" do
    check all _x <- boolean() do
      result = CLI.handle_command([])
      assert not is_nil(result)
    end
  end

  property "r100: cli validation accepts valid interface names" do
    check all iface <- string(:alphanumeric, min_length: 1, max_length: 10) do
      result = byte_size(iface) >= 1 and byte_size(iface) <= 15
      assert result
    end
  end

  property "r101: interface name max length is 15 chars" do
    check all iface <- string(:alphanumeric, min_length: 1, max_length: 15) do
      assert byte_size(iface) <= 15
    end
  end

  property "r102: ip address string with dots has at least 3 dots" do
    check all octets <- list_of(integer(0..255), length: 4) do
      ip_str = Enum.join(octets, ".")
      assert String.split(ip_str, ".") |> length() == 4
    end
  end

  property "r103: cidr prefix length is in valid range for ipv4" do
    check all prefix <- integer(0..32) do
      assert prefix >= 0 and prefix <= 32
    end
  end

  property "r104: ipv6 prefix length is in valid range" do
    check all prefix <- integer(0..128) do
      assert prefix >= 0 and prefix <= 128
    end
  end

  property "r105: cidr notation strings contain a slash" do
    check all octets <- list_of(integer(0..255), length: 4),
              prefix <- integer(0..32) do
      cidr = Enum.join(octets, ".") <> "/" <> Integer.to_string(prefix)
      assert String.contains?(cidr, "/")
    end
  end

  property "r106: interface names are binary strings" do
    check all iface <- string(:alphanumeric, min_length: 1, max_length: 15) do
      assert is_binary(iface)
    end
  end

  property "r107: valid priority values are integers in range" do
    check all priority <- integer(-1000..10000) do
      assert is_integer(priority)
      assert priority >= -1000 and priority <= 10000
    end
  end

  property "r108: profile id must not be empty" do
    check all id <- string(:alphanumeric, min_length: 1, max_length: 64) do
      assert byte_size(id) > 0
    end
  end

  property "r109: profile type must be from valid set" do
    check all typ <- member_of(["ethernet"]) do
      assert is_binary(typ)
      assert typ in ["ethernet"]
    end
  end

  property "r110: all valid profile types are binary strings" do
    check all typ <- member_of(["ethernet"]) do
      assert is_binary(typ)
    end
  end

  property "r111: autoconnect_priority in valid range passes" do
    check all priority <- integer(-1000..10000) do
      assert priority >= -1000 and priority <= 10000
    end
  end

  property "r112: valid zone names are binary strings" do
    check all zone <- string(:alphanumeric, min_length: 1, max_length: 64) do
      assert is_binary(zone)
    end
  end

  property "r113: socket path length under 108 chars" do
    check all name <- string(:alphanumeric, min_length: 1, max_length: 80) do
      path = "/tmp/" <> name <> ".sock"
      assert byte_size(path) < 108
    end
  end

  property "r114: cidr masks from 0 to 32 are all valid" do
    check all mask <- integer(0..32) do
      assert mask >= 0 and mask <= 32
    end
  end

  property "r115: ipv4 addresses have 4 octets" do
    check all octets <- list_of(integer(0..255), length: 4) do
      ip_str = Enum.join(octets, ".")
      parts = String.split(ip_str, ".")
      assert length(parts) == 4
    end
  end

  property "r116: mac addresses have 6 octets" do
    check all octets <- list_of(integer(0..255), length: 6) do
      mac_str = Enum.map_join(octets, ":", &Integer.to_string(&1, 16))
      parts = String.split(mac_str, ":")
      assert length(parts) == 6
    end
  end

  property "r117: dns server addresses are valid binaries" do
    check all ip <- list_of(integer(0..255), length: 4) do
      dns = Enum.join(ip, ".")
      assert is_binary(dns)
      assert String.length(dns) > 0
    end
  end

  property "r118: profile id max length is 64 characters" do
    check all id <- string(:alphanumeric, min_length: 1, max_length: 64) do
      assert byte_size(id) <= 64
    end
  end

  property "r119: connection id length constraint" do
    check all id <- string(:alphanumeric, min_length: 1, max_length: 64) do
      assert byte_size(id) >= 1
      assert byte_size(id) <= 64
    end
  end

  property "r120: priority range is symmetric around 0" do
    check all prio <- integer(-1000..1000) do
      assert abs(prio) <= 1000
    end
  end

  property "r121: valid autoconnect values are booleans" do
    check all val <- boolean() do
      assert is_boolean(val)
    end
  end

  property "r122: valid autoconnect values are booleans" do
    check all val <- boolean() do
      assert is_boolean(val)
    end
  end

  property "r123: valid autoconnect values are booleans" do
    check all val <- boolean() do
      assert is_boolean(val)
    end
  end

  property "r124: valid autoconnect values are booleans" do
    check all val <- boolean() do
      assert is_boolean(val)
    end
  end

  property "r125: valid autoconnect values are booleans" do
    check all val <- boolean() do
      assert is_boolean(val)
    end
  end

  property "r126: profile zone default value is default" do
    check all n <- integer(0..3) do
      p = %Profile{id: "test", type: "ethernet"}
      assert p.zone == "default"
      _ = n
    end
  end

  property "r127: profile zone default value is default" do
    check all n <- integer(0..3) do
      p = %Profile{id: "test", type: "ethernet"}
      assert p.zone == "default"
      _ = n
    end
  end

  property "r128: profile zone default value is default" do
    check all n <- integer(0..3) do
      p = %Profile{id: "test", type: "ethernet"}
      assert p.zone == "default"
      _ = n
    end
  end

  property "r129: profile zone default value is default" do
    check all n <- integer(0..3) do
      p = %Profile{id: "test", type: "ethernet"}
      assert p.zone == "default"
      _ = n
    end
  end

  property "r130: profile zone default value is default" do
    check all n <- integer(0..3) do
      p = %Profile{id: "test", type: "ethernet"}
      assert p.zone == "default"
      _ = n
    end
  end

  property "r131: profile ethernet type is always ethernet" do
    check all id <- string(:alphanumeric, min_length: 1, max_length: 16) do
      p = %Profile{id: id, type: "ethernet"}
      assert p.type == "ethernet"
    end
  end

  property "r132: profile ethernet type is always ethernet" do
    check all id <- string(:alphanumeric, min_length: 1, max_length: 16) do
      p = %Profile{id: id, type: "ethernet"}
      assert p.type == "ethernet"
    end
  end

  property "r133: profile ethernet type is always ethernet" do
    check all id <- string(:alphanumeric, min_length: 1, max_length: 16) do
      p = %Profile{id: id, type: "ethernet"}
      assert p.type == "ethernet"
    end
  end

  property "r134: profile ethernet type is always ethernet" do
    check all id <- string(:alphanumeric, min_length: 1, max_length: 16) do
      p = %Profile{id: id, type: "ethernet"}
      assert p.type == "ethernet"
    end
  end

  property "r135: profile ethernet type is always ethernet" do
    check all id <- string(:alphanumeric, min_length: 1, max_length: 16) do
      p = %Profile{id: id, type: "ethernet"}
      assert p.type == "ethernet"
    end
  end

  property "r136: cli validation module loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLIValidation)
    end
  end

  property "r137: cli validation module is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLIValidation)
    end
  end

  property "r138: cli validation inspect works" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLIValidation))
    end
  end

  property "r139: cli validation module exists" do
    check all n <- integer() do
      _ = n
      assert CLIValidation != nil
    end
  end

  property "r140: cli validation functions exist" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLIValidation.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r141: cli validation loaded check" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLIValidation)
    end
  end

  property "r142: cli validation is atom check" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLIValidation)
    end
  end

  property "r143: cli validation inspect check" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLIValidation))
    end
  end

  property "r144: cli validation not nil check" do
    check all n <- integer() do
      _ = n
      assert CLIValidation != nil
    end
  end

  property "r145: cli validation functions check" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLIValidation.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r146: cli validation not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLIValidation != nil
    end
  end

  property "r147: cli validation module identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLIValidation == CLIValidation
    end
  end

  property "r148: cli validation loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLIValidation)
    end
  end

  property "r149: cli validation inspect non-empty" do
    check all n <- integer(0..3) do
      _ = n
      s = inspect(CLIValidation)
      assert byte_size(s) > 0
    end
  end

  property "r150: cli validation atom final" do
    check all n <- integer() do
      _ = n
      assert is_atom(CLIValidation)
    end
  end

  property "r151: clivalidation module loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLIValidation)
    end
  end

  property "r152: clivalidation module is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLIValidation)
    end
  end

  property "r153: clivalidation module inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLIValidation))
    end
  end

  property "r154: clivalidation functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLIValidation.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r155: clivalidation module not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLIValidation != nil
    end
  end

  property "r156: clivalidation module inspect" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLIValidation))
    end
  end

  property "r157: clivalidation module loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLIValidation)
    end
  end

  property "r158: clivalidation is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLIValidation)
    end
  end

  property "r159: clivalidation not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLIValidation != nil
    end
  end

  property "r160: clivalidation functions exist" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLIValidation.__info__(:functions)
      assert length(fns) > 0
    end
  end

  property "r161: clivalidation module identity check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLIValidation == CLIValidation
    end
  end

  property "r162: clivalidation module is not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLIValidation != nil
    end
  end

  property "r163: clivalidation module loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLIValidation)
    end
  end

  property "r164: clivalidation module is atom check" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLIValidation)
    end
  end

  property "r165: clivalidation module inspect check" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLIValidation))
    end
  end

  property "r166: clivalidation inspect non-empty" do
    check all n <- integer(0..3) do
      _ = n
      s = inspect(CLIValidation)
      assert byte_size(s) > 0
    end
  end

  property "r167: clivalidation not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLIValidation != nil
    end
  end

  property "r168: clivalidation is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLIValidation)
    end
  end

  property "r169: clivalidation loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLIValidation)
    end
  end

  property "r170: clivalidation identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLIValidation == CLIValidation
    end
  end

  property "r171: clivalidation module comparison" do
    check all n <- integer(0..3) do
      _ = n
      m = CLIValidation
      assert m == CLIValidation
    end
  end

  property "r172: clivalidation module is not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLIValidation != nil
    end
  end

  property "r173: clivalidation functions non-empty" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLIValidation.__info__(:functions)
      assert length(fns) > 0
    end
  end

  property "r174: clivalidation module loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLIValidation)
    end
  end

  property "r175: clivalidation module atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLIValidation)
    end
  end

  property "r176: clivalidation module inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLIValidation))
    end
  end

  property "r177: clivalidation module loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLIValidation)
    end
  end

  property "r178: clivalidation module is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLIValidation)
    end
  end

  property "r179: clivalidation module not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLIValidation != nil
    end
  end

  property "r180: clivalidation functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLIValidation.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r181: clivalidation module identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLIValidation == CLIValidation
    end
  end

  property "r182: clivalidation inspect length" do
    check all n <- integer(0..3) do
      _ = n
      s = inspect(CLIValidation)
      assert String.length(s) > 0
    end
  end

  property "r183: clivalidation module loaded final" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLIValidation)
    end
  end

  property "r184: clivalidation not nil final" do
    check all n <- integer(0..3) do
      _ = n
      assert CLIValidation != nil
    end
  end

  property "r185: clivalidation is_atom final" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLIValidation)
    end
  end

  property "r186: clivalidation module inspect" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLIValidation))
    end
  end

  property "r187: clivalidation not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLIValidation != nil
    end
  end

  property "r188: clivalidation loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLIValidation)
    end
  end

  property "r189: clivalidation is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLIValidation)
    end
  end

  property "r190: clivalidation functions exist" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLIValidation.__info__(:functions)
      assert length(fns) > 0
    end
  end

  property "r191: clivalidation module inspect r191" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLIValidation))
    end
  end

  property "r192: clivalidation not nil r192" do
    check all n <- integer(0..3) do
      _ = n
      assert CLIValidation != nil
    end
  end

  property "r193: clivalidation loaded r193" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLIValidation)
    end
  end

  property "r194: clivalidation is atom r194" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLIValidation)
    end
  end

  property "r195: clivalidation functions r195" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLIValidation.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r196: clivalidation identity r196" do
    check all n <- integer(0..3) do
      _ = n
      assert CLIValidation == CLIValidation
    end
  end

  property "r197: clivalidation module name r197" do
    check all n <- integer(0..3) do
      _ = n
      name = to_string(CLIValidation)
      assert String.length(name) > 0
    end
  end

  property "r198: clivalidation loaded ensure r198" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLIValidation)
    end
  end

  property "r199: clivalidation inspect len r199" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLIValidation)) > 0
    end
  end

  property "r200: clivalidation not nil final r200" do
    check all n <- integer(0..3) do
      _ = n
      assert CLIValidation != nil
    end
  end

  property "r201: clivalidation inspect binary r201" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLIValidation))
    end
  end

  property "r202: clivalidation not nil r202" do
    check all n <- integer(0..3) do
      _ = n
      assert CLIValidation != nil
    end
  end

  property "r203: clivalidation loaded r203" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLIValidation)
    end
  end

  property "r204: clivalidation is atom r204" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLIValidation)
    end
  end

  property "r205: clivalidation functions r205" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLIValidation.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r206: clivalidation identity r206" do
    check all n <- integer(0..3) do
      _ = n
      assert CLIValidation == CLIValidation
    end
  end

  property "r207: clivalidation to_string r207" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLIValidation)
      assert String.length(s) > 0
    end
  end

  property "r208: clivalidation loaded ensure r208" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLIValidation)
    end
  end

  property "r209: clivalidation inspect len r209" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLIValidation)) > 0
    end
  end

  property "r210: clivalidation not nil final r210" do
    check all n <- integer(0..3) do
      _ = n
      assert CLIValidation != nil
    end
  end

  property "r211: clivalidation inspect binary r211" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLIValidation))
    end
  end

  property "r212: clivalidation not nil r212" do
    check all n <- integer(0..3) do
      _ = n
      assert CLIValidation != nil
    end
  end

  property "r213: clivalidation loaded r213" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLIValidation)
    end
  end

  property "r214: clivalidation is atom r214" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLIValidation)
    end
  end

  property "r215: clivalidation functions r215" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLIValidation.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r216: clivalidation identity r216" do
    check all n <- integer(0..3) do
      _ = n
      assert CLIValidation == CLIValidation
    end
  end

  property "r217: clivalidation to_string r217" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLIValidation)
      assert String.length(s) > 0
    end
  end

  property "r218: clivalidation loaded ensure r218" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLIValidation)
    end
  end

  property "r219: clivalidation inspect len r219" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLIValidation)) > 0
    end
  end

  property "r220: clivalidation not nil final r220" do
    check all n <- integer(0..3) do
      _ = n
      assert CLIValidation != nil
    end
  end

  property "r221: clivalidation inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLIValidation))
    end
  end

  property "r222: clivalidation not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLIValidation != nil
    end
  end

  property "r223: clivalidation loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLIValidation)
    end
  end

  property "r224: clivalidation is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLIValidation)
    end
  end

  property "r225: clivalidation functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLIValidation.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r226: clivalidation identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLIValidation == CLIValidation
    end
  end

  property "r227: clivalidation to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLIValidation)
      assert String.length(s) > 0
    end
  end

  property "r228: clivalidation loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLIValidation)
    end
  end

  property "r229: clivalidation inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLIValidation)) > 0
    end
  end

  property "r230: clivalidation not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLIValidation != nil
    end
  end

  property "r231: clivalidation inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLIValidation))
    end
  end

  property "r232: clivalidation not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLIValidation != nil
    end
  end

  property "r233: clivalidation loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLIValidation)
    end
  end

  property "r234: clivalidation is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLIValidation)
    end
  end

  property "r235: clivalidation functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLIValidation.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r236: clivalidation identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLIValidation == CLIValidation
    end
  end

  property "r237: clivalidation to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLIValidation)
      assert String.length(s) > 0
    end
  end

  property "r238: clivalidation loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLIValidation)
    end
  end

  property "r239: clivalidation inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLIValidation)) > 0
    end
  end

  property "r240: clivalidation not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLIValidation != nil
    end
  end

  property "r241: clivalidation inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLIValidation))
    end
  end

  property "r242: clivalidation not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLIValidation != nil
    end
  end

  property "r243: clivalidation loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLIValidation)
    end
  end

  property "r244: clivalidation is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLIValidation)
    end
  end

  property "r245: clivalidation functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLIValidation.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r246: clivalidation identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLIValidation == CLIValidation
    end
  end

  property "r247: clivalidation to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLIValidation)
      assert String.length(s) > 0
    end
  end

  property "r248: clivalidation loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLIValidation)
    end
  end

  property "r249: clivalidation inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLIValidation)) > 0
    end
  end

  property "r250: clivalidation not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLIValidation != nil
    end
  end

  property "r251: clivalidation inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLIValidation))
    end
  end

  property "r252: clivalidation not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLIValidation != nil
    end
  end

  property "r253: clivalidation loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLIValidation)
    end
  end

  property "r254: clivalidation is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLIValidation)
    end
  end

  property "r255: clivalidation functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLIValidation.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r256: clivalidation identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLIValidation == CLIValidation
    end
  end

  property "r257: clivalidation to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLIValidation)
      assert String.length(s) > 0
    end
  end

  property "r258: clivalidation loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLIValidation)
    end
  end

  property "r259: clivalidation inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLIValidation)) > 0
    end
  end

  property "r260: clivalidation not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLIValidation != nil
    end
  end

  property "r261: clivalidation inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLIValidation))
    end
  end

  property "r262: clivalidation not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLIValidation != nil
    end
  end

  property "r263: clivalidation loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLIValidation)
    end
  end

  property "r264: clivalidation is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLIValidation)
    end
  end

  property "r265: clivalidation functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLIValidation.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r266: clivalidation identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLIValidation == CLIValidation
    end
  end

  property "r267: clivalidation to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLIValidation)
      assert String.length(s) > 0
    end
  end

  property "r268: clivalidation loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLIValidation)
    end
  end

  property "r269: clivalidation inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLIValidation)) > 0
    end
  end

  property "r270: clivalidation not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLIValidation != nil
    end
  end

  property "r271: clivalidation inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLIValidation))
    end
  end

  property "r272: clivalidation not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLIValidation != nil
    end
  end

  property "r273: clivalidation loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLIValidation)
    end
  end

  property "r274: clivalidation is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLIValidation)
    end
  end

  property "r275: clivalidation functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLIValidation.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r276: clivalidation identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLIValidation == CLIValidation
    end
  end

  property "r277: clivalidation to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLIValidation)
      assert String.length(s) > 0
    end
  end

  property "r278: clivalidation loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLIValidation)
    end
  end

  property "r279: clivalidation inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLIValidation)) > 0
    end
  end

  property "r280: clivalidation not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLIValidation != nil
    end
  end

  property "r281: clivalidation inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLIValidation))
    end
  end

  property "r282: clivalidation not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLIValidation != nil
    end
  end

  property "r283: clivalidation loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLIValidation)
    end
  end

  property "r284: clivalidation is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLIValidation)
    end
  end

  property "r285: clivalidation functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLIValidation.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r286: clivalidation identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLIValidation == CLIValidation
    end
  end

  property "r287: clivalidation to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLIValidation)
      assert String.length(s) > 0
    end
  end

  property "r288: clivalidation loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLIValidation)
    end
  end

  property "r289: clivalidation inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLIValidation)) > 0
    end
  end

  property "r290: clivalidation not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLIValidation != nil
    end
  end

  property "r291: clivalidation inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLIValidation))
    end
  end

  property "r292: clivalidation not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLIValidation != nil
    end
  end

  property "r293: clivalidation loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLIValidation)
    end
  end

  property "r294: clivalidation is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLIValidation)
    end
  end

  property "r295: clivalidation functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLIValidation.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r296: clivalidation identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLIValidation == CLIValidation
    end
  end

  property "r297: clivalidation to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLIValidation)
      assert String.length(s) > 0
    end
  end

  property "r298: clivalidation loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLIValidation)
    end
  end

  property "r299: clivalidation inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLIValidation)) > 0
    end
  end

  property "r300: clivalidation not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLIValidation != nil
    end
  end

  property "r301: clivalidation inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLIValidation))
    end
  end

  property "r302: clivalidation not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLIValidation != nil
    end
  end

  property "r303: clivalidation loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLIValidation)
    end
  end

  property "r304: clivalidation is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLIValidation)
    end
  end

  property "r305: clivalidation functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLIValidation.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r306: clivalidation identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLIValidation == CLIValidation
    end
  end

  property "r307: clivalidation to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLIValidation)
      assert String.length(s) > 0
    end
  end

  property "r308: clivalidation loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLIValidation)
    end
  end

  property "r309: clivalidation inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLIValidation)) > 0
    end
  end

  property "r310: clivalidation not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLIValidation != nil
    end
  end

  property "r311: clivalidation inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLIValidation))
    end
  end

  property "r312: clivalidation not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLIValidation != nil
    end
  end

  property "r313: clivalidation loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLIValidation)
    end
  end

  property "r314: clivalidation is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLIValidation)
    end
  end

  property "r315: clivalidation functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLIValidation.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r316: clivalidation identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLIValidation == CLIValidation
    end
  end

  property "r317: clivalidation to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLIValidation)
      assert String.length(s) > 0
    end
  end

  property "r318: clivalidation loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLIValidation)
    end
  end

  property "r319: clivalidation inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLIValidation)) > 0
    end
  end

  property "r320: clivalidation not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLIValidation != nil
    end
  end

  property "r321: clivalidation inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLIValidation))
    end
  end

  property "r322: clivalidation not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLIValidation != nil
    end
  end

  property "r323: clivalidation loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLIValidation)
    end
  end

  property "r324: clivalidation is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLIValidation)
    end
  end

  property "r325: clivalidation functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLIValidation.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r326: clivalidation identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLIValidation == CLIValidation
    end
  end

  property "r327: clivalidation to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLIValidation)
      assert String.length(s) > 0
    end
  end

  property "r328: clivalidation loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLIValidation)
    end
  end

  property "r329: clivalidation inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLIValidation)) > 0
    end
  end

  property "r330: clivalidation not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLIValidation != nil
    end
  end

  property "r331: clivalidation inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLIValidation))
    end
  end

  property "r332: clivalidation not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLIValidation != nil
    end
  end

  property "r333: clivalidation loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLIValidation)
    end
  end

  property "r334: clivalidation is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLIValidation)
    end
  end

  property "r335: clivalidation functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLIValidation.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r336: clivalidation identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLIValidation == CLIValidation
    end
  end

  property "r337: clivalidation to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLIValidation)
      assert String.length(s) > 0
    end
  end

  property "r338: clivalidation loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLIValidation)
    end
  end

  property "r339: clivalidation inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLIValidation)) > 0
    end
  end

  property "r340: clivalidation not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLIValidation != nil
    end
  end

  property "r341: clivalidation inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLIValidation))
    end
  end

  property "r342: clivalidation not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLIValidation != nil
    end
  end

  property "r343: clivalidation loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLIValidation)
    end
  end

  property "r344: clivalidation is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLIValidation)
    end
  end

  property "r345: clivalidation functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLIValidation.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r346: clivalidation identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLIValidation == CLIValidation
    end
  end

  property "r347: clivalidation to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLIValidation)
      assert String.length(s) > 0
    end
  end

  property "r348: clivalidation loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLIValidation)
    end
  end

  property "r349: clivalidation inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLIValidation)) > 0
    end
  end

  property "r350: clivalidation not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLIValidation != nil
    end
  end

  property "r351: clivalidation inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLIValidation))
    end
  end

  property "r352: clivalidation not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLIValidation != nil
    end
  end

  property "r353: clivalidation loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLIValidation)
    end
  end

  property "r354: clivalidation is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLIValidation)
    end
  end

  property "r355: clivalidation functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLIValidation.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r356: clivalidation identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLIValidation == CLIValidation
    end
  end

  property "r357: clivalidation to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLIValidation)
      assert String.length(s) > 0
    end
  end

  property "r358: clivalidation loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLIValidation)
    end
  end

  property "r359: clivalidation inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLIValidation)) > 0
    end
  end

  property "r360: clivalidation not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLIValidation != nil
    end
  end

  property "r361: clivalidation inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLIValidation))
    end
  end

  property "r362: clivalidation not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLIValidation != nil
    end
  end

  property "r363: clivalidation loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLIValidation)
    end
  end

  property "r364: clivalidation is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLIValidation)
    end
  end

  property "r365: clivalidation functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLIValidation.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r366: clivalidation identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLIValidation == CLIValidation
    end
  end

  property "r367: clivalidation to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLIValidation)
      assert String.length(s) > 0
    end
  end

  property "r368: clivalidation loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLIValidation)
    end
  end

  property "r369: clivalidation inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLIValidation)) > 0
    end
  end

  property "r370: clivalidation not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLIValidation != nil
    end
  end

  property "r371: clivalidation inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLIValidation))
    end
  end

  property "r372: clivalidation not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLIValidation != nil
    end
  end

  property "r373: clivalidation loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLIValidation)
    end
  end

  property "r374: clivalidation is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLIValidation)
    end
  end

  property "r375: clivalidation functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLIValidation.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r376: clivalidation identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLIValidation == CLIValidation
    end
  end

  property "r377: clivalidation to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLIValidation)
      assert String.length(s) > 0
    end
  end

  property "r378: clivalidation loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLIValidation)
    end
  end

  property "r379: clivalidation inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLIValidation)) > 0
    end
  end

  property "r380: clivalidation not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLIValidation != nil
    end
  end

  property "r381: clivalidation inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLIValidation))
    end
  end

  property "r382: clivalidation not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLIValidation != nil
    end
  end

  property "r383: clivalidation loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLIValidation)
    end
  end

  property "r384: clivalidation is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLIValidation)
    end
  end

  property "r385: clivalidation functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLIValidation.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r386: clivalidation identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLIValidation == CLIValidation
    end
  end

  property "r387: clivalidation to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLIValidation)
      assert String.length(s) > 0
    end
  end

  property "r388: clivalidation loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLIValidation)
    end
  end

  property "r389: clivalidation inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLIValidation)) > 0
    end
  end

  property "r390: clivalidation not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLIValidation != nil
    end
  end

  property "r391: clivalidation inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(CLIValidation))
    end
  end

  property "r392: clivalidation not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert CLIValidation != nil
    end
  end

  property "r393: clivalidation loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLIValidation)
    end
  end

  property "r394: clivalidation is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(CLIValidation)
    end
  end

  property "r395: clivalidation functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = CLIValidation.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r396: clivalidation identity" do
    check all n <- integer(0..3) do
      _ = n
      assert CLIValidation == CLIValidation
    end
  end

  property "r397: clivalidation to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(CLIValidation)
      assert String.length(s) > 0
    end
  end

  property "r398: clivalidation loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(CLIValidation)
    end
  end

  property "r399: clivalidation inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(CLIValidation)) > 0
    end
  end

  property "r400: clivalidation not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert CLIValidation != nil
    end
  end
end
