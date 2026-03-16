defmodule YellowDog.Store.CLITest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias YellowDog.Store.CLI

  describe "main/1 with unknown command" do
    test "prints unknown command message" do
      output = capture_io(fn -> CLI.main(["unknown"]) end)
      assert output =~ "Unknown command"
    end

    test "prints the arguments in the error message" do
      output = capture_io(fn -> CLI.main(["foo", "bar"]) end)
      assert output =~ "Unknown command"
    end
  end

  describe "main/1 with empty args" do
    test "prints unknown command for empty list" do
      output = capture_io(fn -> CLI.main([]) end)
      assert output =~ "Unknown command"
    end
  end

  describe "backup subcommand routing" do
    test "unknown backup subcommand prints help" do
      output = capture_io(fn -> CLI.main(["backup", "unknown_sub"]) end)
      assert output =~ "Unknown backup command"
      assert output =~ "Available: create, restore, list"
    end

    test "backup with no subcommand prints help" do
      output = capture_io(fn -> CLI.main(["backup"]) end)
      assert output =~ "Unknown backup command"
      assert output =~ "Available:"
    end
  end

  describe "backup restore argument validation" do
    test "restore without --file prints error" do
      output = capture_io(fn -> CLI.main(["backup", "restore"]) end)
      assert output =~ "--file is required"
    end

    test "restore with --file but no --yes prints confirmation warning" do
      output = capture_io(fn -> CLI.main(["backup", "restore", "--file", "/tmp/test.backup"]) end)
      assert output =~ "overwrite all current data"
      assert output =~ "--yes"
    end
  end
end
