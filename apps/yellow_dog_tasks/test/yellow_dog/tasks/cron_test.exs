defmodule YellowDog.Tasks.CronTest do
  use ExUnit.Case, async: true

  alias YellowDog.Tasks.Cron

  test "matches simple cron expressions" do
    monday = ~U[2026-06-29 03:30:00Z]

    assert Cron.due?("30 3 * * MON", monday)
    assert Cron.due?("*/15 3 * * *", monday)
    refute Cron.due?("0 3 * * MON", monday)
  end

  test "rejects invalid cron expressions" do
    assert {:error, _reason} = Cron.parse("60 * * * *")
    assert {:error, _reason} = Cron.parse("* * *")
  end
end
