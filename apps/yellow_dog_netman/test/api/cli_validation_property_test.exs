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
end
