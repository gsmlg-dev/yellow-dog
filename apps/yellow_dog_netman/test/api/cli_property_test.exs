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
end
