defmodule YellowDog.Console.Assets.IconFallbackTest do
  use ExUnit.Case, async: true

  test "app CSS gives DuskMoon SVG icons intrinsic fallback dimensions" do
    css_path = Path.expand("../../../../assets/css/app.css", __DIR__)
    css = File.read!(css_path)

    assert css =~ "WORKAROUND(upstream): duskmoon-dev/phoenix-duskmoon-ui#29"

    assert css =~
             ~S|:where(svg[viewBox="0 0 24 24"][aria-hidden="true"]:not([width]):not([height]))|

    assert css =~ "width: 1em;"
    assert css =~ "height: 1em;"
  end
end
