defmodule YellowDog.Console.ErrorJSONTest do
  use YellowDog.Console.ConnCase, async: true

  alias YellowDog.Console.ErrorJSON

  test "renders 404" do
    assert ErrorJSON.render("404.json", %{}) == %{
             errors: %{detail: "Not Found"}
           }
  end

  test "renders 500" do
    assert ErrorJSON.render("500.json", %{}) ==
             %{errors: %{detail: "Internal Server Error"}}
  end

  test "catch-all renders status message from template" do
    result = ErrorJSON.render("400.json", %{})
    assert %{errors: %{detail: "Bad Request"}} = result
  end

  test "catch-all renders 422" do
    result = ErrorJSON.render("422.json", %{})
    assert %{errors: %{detail: "Unprocessable Entity"}} = result
  end
end
