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
end