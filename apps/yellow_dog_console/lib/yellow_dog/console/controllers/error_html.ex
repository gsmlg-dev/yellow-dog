defmodule YellowDog.Console.ErrorHTML do
  @moduledoc """
  Renders error pages for the console application.
  """

  use YellowDog.Console, :html

  # If you want to customize your error pages,
  # you can create new HTML templates or use the default Phoenix ones.

  def render("404.html", _assigns) do
    "Not Found"
  end

  def render("500.html", _assigns) do
    "Internal Server Error"
  end

  # Catch-all for other error codes
  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
