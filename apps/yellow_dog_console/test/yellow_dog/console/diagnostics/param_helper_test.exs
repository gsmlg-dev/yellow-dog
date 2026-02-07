defmodule YellowDog.Console.Diagnostics.ParamHelperTest do
  use ExUnit.Case, async: true

  alias YellowDog.Console.Diagnostics.ParamHelper

  describe "get_string/2" do
    test "gets value by atom key" do
      assert ParamHelper.get_string(%{server: "8.8.8.8"}, :server) == "8.8.8.8"
    end

    test "gets value by string key" do
      assert ParamHelper.get_string(%{"server" => "8.8.8.8"}, :server) == "8.8.8.8"
    end

    test "prefers atom key over string key" do
      params = Map.put(%{server: "atom"}, "server", "string")
      assert ParamHelper.get_string(params, :server) == "atom"
    end

    test "returns empty string when key is missing" do
      assert ParamHelper.get_string(%{}, :server) == ""
    end

    test "returns empty string for nil value" do
      assert ParamHelper.get_string(%{server: nil}, :server) == ""
    end
  end

  describe "get_integer/3" do
    test "returns integer value by atom key" do
      assert ParamHelper.get_integer(%{port: 53}, :port, 80) == 53
    end

    test "returns integer value by string key" do
      assert ParamHelper.get_integer(%{"port" => 53}, :port, 80) == 53
    end

    test "coerces string to integer" do
      assert ParamHelper.get_integer(%{"port" => "8080"}, :port, 80) == 8080
    end

    test "returns default for non-numeric string" do
      assert ParamHelper.get_integer(%{"port" => "abc"}, :port, 80) == 80
    end

    test "returns default for partial numeric string" do
      assert ParamHelper.get_integer(%{"port" => "53abc"}, :port, 80) == 80
    end

    test "returns default when key is missing" do
      assert ParamHelper.get_integer(%{}, :port, 80) == 80
    end

    test "returns default for nil value" do
      assert ParamHelper.get_integer(%{port: nil}, :port, 80) == 80
    end

    test "handles zero by atom key (falsy value regression)" do
      assert ParamHelper.get_integer(%{timeout: 0}, :timeout, 5000) == 0
    end

    test "handles zero by string key (falsy value regression)" do
      assert ParamHelper.get_integer(%{"timeout" => 0}, :timeout, 5000) == 0
    end

    test "handles negative integers" do
      assert ParamHelper.get_integer(%{"offset" => -10}, :offset, 0) == -10
    end

    test "handles string negative integers" do
      assert ParamHelper.get_integer(%{"offset" => "-5"}, :offset, 0) == -5
    end
  end

  describe "get_boolean/3" do
    test "returns boolean value by atom key" do
      assert ParamHelper.get_boolean(%{recurse: true}, :recurse, false) == true
    end

    test "returns boolean value by string key" do
      assert ParamHelper.get_boolean(%{"recurse" => false}, :recurse, true) == false
    end

    test "coerces string 'true' to true" do
      assert ParamHelper.get_boolean(%{"recurse" => "true"}, :recurse, false) == true
    end

    test "coerces string 'false' to false" do
      assert ParamHelper.get_boolean(%{"recurse" => "false"}, :recurse, true) == false
    end

    test "returns default for other strings" do
      assert ParamHelper.get_boolean(%{"recurse" => "yes"}, :recurse, false) == false
    end

    test "returns default when key is missing" do
      assert ParamHelper.get_boolean(%{}, :recurse, true) == true
    end

    test "returns default for nil value" do
      assert ParamHelper.get_boolean(%{recurse: nil}, :recurse, true) == true
    end

    test "handles false by atom key (falsy value regression)" do
      assert ParamHelper.get_boolean(%{recurse: false}, :recurse, true) == false
    end

    test "handles false by string key (falsy value regression)" do
      assert ParamHelper.get_boolean(%{"recurse" => false}, :recurse, true) == false
    end
  end

  describe "format_error/1" do
    test "formats :timeout" do
      assert ParamHelper.format_error(:timeout) == "Query timed out"
    end

    test "formats socket error" do
      assert ParamHelper.format_error({:socket_error, :econnrefused}) ==
               "Socket error: :econnrefused"
    end

    test "formats parse error" do
      assert ParamHelper.format_error({:parse_error, "invalid DNS message"}) ==
               "Parse error: invalid DNS message"
    end

    test "formats build error" do
      assert ParamHelper.format_error({:build_error, "missing domain"}) ==
               "Build error: missing domain"
    end

    test "formats unknown errors with inspect" do
      assert ParamHelper.format_error(:unknown_error) == ":unknown_error"
    end

    test "formats complex error terms" do
      assert ParamHelper.format_error({:error, :nxdomain}) == "{:error, :nxdomain}"
    end
  end
end
