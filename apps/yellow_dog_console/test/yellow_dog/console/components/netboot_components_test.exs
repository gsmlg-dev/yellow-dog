defmodule YellowDog.Console.NetbootComponentsTest do
  use ExUnit.Case, async: true

  alias YellowDog.Console.NetbootComponents

  describe "format_datetime/1" do
    test "returns dash for nil" do
      assert NetbootComponents.format_datetime(nil) == "-"
    end

    test "formats DateTime as YYYY-MM-DD HH:MM" do
      {:ok, dt, _} = DateTime.from_iso8601("2025-06-20T09:15:00Z")
      assert NetbootComponents.format_datetime(dt) == "2025-06-20 09:15"
    end

    test "formats midnight correctly" do
      {:ok, dt, _} = DateTime.from_iso8601("2025-01-01T00:00:00Z")
      assert NetbootComponents.format_datetime(dt) == "2025-01-01 00:00"
    end
  end

  describe "format_datetime_full/1" do
    test "returns dash for nil" do
      assert NetbootComponents.format_datetime_full(nil) == "-"
    end

    test "formats DateTime with seconds" do
      {:ok, dt, _} = DateTime.from_iso8601("2025-06-20T09:15:30Z")
      assert NetbootComponents.format_datetime_full(dt) == "2025-06-20 09:15:30"
    end
  end

  describe "format_time_ago/1" do
    test "returns dash for nil" do
      assert NetbootComponents.format_time_ago(nil) == "-"
    end

    test "returns 'just now' for recent timestamps" do
      dt = DateTime.utc_now()
      assert NetbootComponents.format_time_ago(dt) == "just now"
    end

    test "returns minutes ago for timestamps under 1 hour" do
      dt = DateTime.add(DateTime.utc_now(), -300, :second)
      assert NetbootComponents.format_time_ago(dt) == "5m ago"
    end

    test "returns hours ago for timestamps under 1 day" do
      dt = DateTime.add(DateTime.utc_now(), -7200, :second)
      assert NetbootComponents.format_time_ago(dt) == "2h ago"
    end

    test "returns days ago for timestamps under 1 week" do
      dt = DateTime.add(DateTime.utc_now(), -172_800, :second)
      assert NetbootComponents.format_time_ago(dt) == "2d ago"
    end

    test "returns date for timestamps over 1 week" do
      dt = DateTime.add(DateTime.utc_now(), -864_000, :second)
      assert NetbootComponents.format_time_ago(dt) =~ ~r/\d{4}-\d{2}-\d{2}/
    end
  end

  describe "format_size/1" do
    test "formats bytes" do
      assert NetbootComponents.format_size(0) == "0 B"
      assert NetbootComponents.format_size(512) == "512 B"
      assert NetbootComponents.format_size(1023) == "1023 B"
    end

    test "formats kilobytes" do
      assert NetbootComponents.format_size(1024) == "1.0 KB"
      assert NetbootComponents.format_size(1536) == "1.5 KB"
      assert NetbootComponents.format_size(10240) == "10.0 KB"
    end

    test "formats megabytes" do
      assert NetbootComponents.format_size(1_048_576) == "1.0 MB"
      assert NetbootComponents.format_size(5_242_880) == "5.0 MB"
    end

    test "formats gigabytes" do
      assert NetbootComponents.format_size(1_073_741_824) == "1.0 GB"
      assert NetbootComponents.format_size(2_147_483_648) == "2.0 GB"
    end

    test "returns dash for non-integer values" do
      assert NetbootComponents.format_size(nil) == "-"
      assert NetbootComponents.format_size("not a number") == "-"
    end
  end
end
