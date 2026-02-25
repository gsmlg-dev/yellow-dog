defmodule Mix.Tasks.DnsTest do
  @moduledoc """
  Tests for Mix.Tasks.Dns and Mix.Tasks.Dns.Helpers.

  Tests the helper functions and task modules that don't require
  a running application (help text, argument validation, formatting).
  """
  use ExUnit.Case, async: true

  describe "Mix.Tasks.Dns.Helpers" do
    test "format_datetime formats UTC datetime" do
      dt = ~U[2024-06-15 14:30:00Z]
      result = Mix.Tasks.Dns.Helpers.format_datetime(dt)
      assert result == "2024-06-15 14:30:00 UTC"
    end

    test "format_datetime handles midnight" do
      dt = ~U[2024-01-01 00:00:00Z]
      result = Mix.Tasks.Dns.Helpers.format_datetime(dt)
      assert result == "2024-01-01 00:00:00 UTC"
    end

    test "colorize with :green returns text containing original content" do
      result = Mix.Tasks.Dns.Helpers.colorize("ok", :green)
      assert result =~ "ok"
    end

    test "colorize with :yellow returns text containing original content" do
      result = Mix.Tasks.Dns.Helpers.colorize("warn", :yellow)
      assert result =~ "warn"
    end

    test "colorize with :red returns text containing original content" do
      result = Mix.Tasks.Dns.Helpers.colorize("err", :red)
      assert result =~ "err"
    end

    test "colorize with :blue returns text containing original content" do
      result = Mix.Tasks.Dns.Helpers.colorize("info", :blue)
      assert result =~ "info"
    end

    test "colorize returns plain text for unknown color" do
      result = Mix.Tasks.Dns.Helpers.colorize("plain", :purple)
      assert result == "plain"
    end

    test "colorize with known colors returns string" do
      for color <- [:green, :yellow, :red, :blue] do
        result = Mix.Tasks.Dns.Helpers.colorize("test", color)
        assert is_binary(result)
      end
    end
  end

  describe "Mix.Tasks.Dns" do
    test "module is defined" do
      Code.ensure_loaded!(Mix.Tasks.Dns)
      assert function_exported?(Mix.Tasks.Dns, :run, 1)
    end

    test "run/1 prints help text" do
      # Capture shell output by using a custom shell
      Mix.shell(Mix.Shell.Process)

      on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

      Mix.Tasks.Dns.run([])

      assert_received {:mix_shell, :info, [help_text]}
      assert help_text =~ "Available DNS tasks"
      assert help_text =~ "dns.status"
      assert help_text =~ "dns.health"
      assert help_text =~ "dns.metrics"
      assert help_text =~ "dns.views"
      assert help_text =~ "dns.view"
      assert help_text =~ "dns.test"
      assert help_text =~ "dns.reload"
    end
  end

  describe "Mix.Tasks.Dns.View" do
    test "module is defined" do
      Code.ensure_loaded!(Mix.Tasks.Dns.View)
      assert function_exported?(Mix.Tasks.Dns.View, :run, 1)
    end

    test "run/1 with empty args prints usage" do
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

      Mix.Tasks.Dns.View.run([])

      assert_received {:mix_shell, :error, [usage]}
      assert usage =~ "Usage: mix dns.view"
    end
  end

  describe "Mix.Tasks.Dns.Test" do
    test "module is defined" do
      Code.ensure_loaded!(Mix.Tasks.Dns.Test)
      assert function_exported?(Mix.Tasks.Dns.Test, :run, 1)
    end

    test "run/1 with empty args prints usage" do
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

      Mix.Tasks.Dns.Test.run([])

      assert_received {:mix_shell, :error, [usage]}
      assert usage =~ "Usage: mix dns.test"
    end
  end

  describe "Mix.Tasks.Dns.Status" do
    test "module is defined" do
      Code.ensure_loaded!(Mix.Tasks.Dns.Status)
      assert function_exported?(Mix.Tasks.Dns.Status, :run, 1)
    end
  end

  describe "Mix.Tasks.Dns.Health" do
    test "module is defined" do
      Code.ensure_loaded!(Mix.Tasks.Dns.Health)
      assert function_exported?(Mix.Tasks.Dns.Health, :run, 1)
    end
  end

  describe "Mix.Tasks.Dns.Metrics" do
    test "module is defined" do
      Code.ensure_loaded!(Mix.Tasks.Dns.Metrics)
      assert function_exported?(Mix.Tasks.Dns.Metrics, :run, 1)
    end
  end

  describe "Mix.Tasks.Dns.Views" do
    test "module is defined" do
      Code.ensure_loaded!(Mix.Tasks.Dns.Views)
      assert function_exported?(Mix.Tasks.Dns.Views, :run, 1)
    end
  end

  describe "Mix.Tasks.Dns.Reload" do
    test "module is defined" do
      Code.ensure_loaded!(Mix.Tasks.Dns.Reload)
      assert function_exported?(Mix.Tasks.Dns.Reload, :run, 1)
    end
  end
end
