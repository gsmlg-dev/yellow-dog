defmodule YellowDog.Console.IdentityComponentsTest do
  use ExUnit.Case, async: true

  alias YellowDog.Console.IdentityComponents

  describe "status_badge_class/1" do
    test "returns warning badge for :pending" do
      assert IdentityComponents.status_badge_class(:pending) == "badge badge-warning"
    end

    test "returns success badge for :approved" do
      assert IdentityComponents.status_badge_class(:approved) == "badge badge-success"
    end

    test "returns error badge for :revoked" do
      assert IdentityComponents.status_badge_class(:revoked) == "badge badge-error"
    end

    test "returns plain badge for unknown status" do
      assert IdentityComponents.status_badge_class(:unknown) == "badge"
      assert IdentityComponents.status_badge_class(:anything) == "badge"
    end
  end

  describe "event_badge_class/1" do
    test "returns info badge for host.registered" do
      assert IdentityComponents.event_badge_class("host.registered") ==
               "badge badge-info badge-sm"
    end

    test "returns success badge for host.approved" do
      assert IdentityComponents.event_badge_class("host.approved") ==
               "badge badge-success badge-sm"
    end

    test "returns error badge for host.revoked" do
      assert IdentityComponents.event_badge_class("host.revoked") == "badge badge-error badge-sm"
    end

    test "returns warning badge for host.key_rotated" do
      assert IdentityComponents.event_badge_class("host.key_rotated") ==
               "badge badge-warning badge-sm"
    end

    test "returns error outline badge for host.deleted" do
      assert IdentityComponents.event_badge_class("host.deleted") ==
               "badge badge-error badge-outline badge-sm"
    end

    test "returns plain sm badge for unknown event" do
      assert IdentityComponents.event_badge_class("host.unknown") == "badge badge-sm"
      assert IdentityComponents.event_badge_class("") == "badge badge-sm"
    end
  end

  describe "format_time/1" do
    test "returns dash for nil" do
      assert IdentityComponents.format_time(nil) == "-"
    end

    test "formats DateTime as YYYY-MM-DD HH:MM" do
      {:ok, dt, _} = DateTime.from_iso8601("2025-03-15T14:30:00Z")
      assert IdentityComponents.format_time(dt) == "2025-03-15 14:30"
    end

    test "formats midnight correctly" do
      {:ok, dt, _} = DateTime.from_iso8601("2025-01-01T00:00:00Z")
      assert IdentityComponents.format_time(dt) == "2025-01-01 00:00"
    end

    test "returns dash for non-DateTime values" do
      assert IdentityComponents.format_time("not a datetime") == "-"
      assert IdentityComponents.format_time(12345) == "-"
    end
  end

  describe "format_time_detail/1" do
    test "returns dash for nil" do
      assert IdentityComponents.format_time_detail(nil) == "-"
    end

    test "formats DateTime with seconds and UTC suffix" do
      {:ok, dt, _} = DateTime.from_iso8601("2025-03-15T14:30:45Z")
      assert IdentityComponents.format_time_detail(dt) == "2025-03-15 14:30:45 UTC"
    end

    test "returns dash for non-DateTime values" do
      assert IdentityComponents.format_time_detail("not a datetime") == "-"
      assert IdentityComponents.format_time_detail(12345) == "-"
    end
  end
end
