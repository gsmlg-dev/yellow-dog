defmodule YellowDog.Console.ErrorHTMLTest do
  use YellowDog.Console.ConnCase, async: true

  alias YellowDog.Console.ErrorHTML

  test "renders 404 page" do
    assert ErrorHTML.render("404.html", %{}) == "Not Found"
  end

  test "renders 500 page" do
    assert ErrorHTML.render("500.html", %{}) == "Internal Server Error"
  end

  test "catch-all renders status from template" do
    result = ErrorHTML.render("400.html", %{})
    assert result == "Bad Request"
  end

  test "catch-all renders 422" do
    result = ErrorHTML.render("422.html", %{})
    assert result == "Unprocessable Entity"
  end
end
