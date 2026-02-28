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
end
