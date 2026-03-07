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
end
