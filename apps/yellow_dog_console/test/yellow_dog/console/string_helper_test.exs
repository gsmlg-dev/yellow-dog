defmodule YellowDog.Console.StringHelperTest do
  use ExUnit.Case, async: true

  alias YellowDog.Console.StringHelper

  doctest StringHelper

  describe "split_and_trim/2" do
    test "splits by newline and trims whitespace" do
      input = """
      line1
        line2

      line3
      """

      assert StringHelper.split_and_trim(input, "\n") == ["line1", "line2", "line3"]
    end

    test "splits by comma and trims whitespace" do
      input = "a,  b  ,c, d "
      assert StringHelper.split_and_trim(input, ",") == ["a", "b", "c", "d"]
    end

    test "handles empty string" do
      assert StringHelper.split_and_trim("", "\n") == []
    end

    test "handles string with only whitespace" do
      assert StringHelper.split_and_trim("   \n  \n  ", "\n") == []
    end

    test "handles single value" do
      assert StringHelper.split_and_trim("single", "\n") == ["single"]
    end

    test "handles single value with whitespace" do
      assert StringHelper.split_and_trim("  single  ", "\n") == ["single"]
    end

    test "removes empty lines between values" do
      input = "a\n\n\nb\n\nc"
      assert StringHelper.split_and_trim(input, "\n") == ["a", "b", "c"]
    end

    test "works with regex separator" do
      input = "a, b ; c"
      assert StringHelper.split_and_trim(input, ~r/[,;]/) == ["a", "b", "c"]
    end

    test "handles non-string input gracefully" do
      assert StringHelper.split_and_trim(nil, "\n") == []
      assert StringHelper.split_and_trim(123, "\n") == []
    end
  end
end
