defmodule YellowDog.ManagementUI.AppbarVersionTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias YellowDog.Management.BuildInfo
  alias YellowDog.ManagementUI.Layouts

  test "version beside the logo exposes build metadata through a focusable tooltip trigger" do
    info = BuildInfo.info()

    html =
      render_component(&Layouts.app/1, flash: %{}, inner_content: "")
      |> LazyHTML.from_fragment()

    trigger = LazyHTML.query(html, "a[href='/'] + button#app-version.badge-secondary")
    assert LazyHTML.text(trigger) =~ info.display_version
    assert LazyHTML.attribute(trigger, "type") == ["button"]

    assert LazyHTML.attribute(trigger, "aria-label") ==
             ["Version #{info.display_version}; build details"]

    [tooltip_id] = LazyHTML.attribute(trigger, "aria-describedby")
    assert LazyHTML.attribute(trigger, "interestfor") == [tooltip_id]

    tooltip = LazyHTML.query(html, "##{tooltip_id}[role='tooltip'].tooltip-secondary")
    details = LazyHTML.text(tooltip)
    assert details =~ "Version: #{info.version}"
    assert details =~ "Environment: #{info.environment}"
    assert details =~ "Git ref: #{info.git_ref}"
    assert details =~ "Git commit: #{info.git_commit}"
    assert details =~ "Release time: #{info.release_time}"
    assert details =~ "Built at: #{info.built_at}"
    [fallback_details] = LazyHTML.attribute(trigger, "title")
    assert String.trim(details) == fallback_details
    assert LazyHTML.attribute(trigger, "aria-description") == [fallback_details]
  end
end
