defmodule YellowDog.Console.PageController do
  @moduledoc """
  Controller for static pages in the web console.

  Handles the home page and any other non-LiveView routes.
  """

  use YellowDog.Console, :controller

  def home(conn, _params) do
    # The home page is often custom made,
    # so skip the default app layout.
    render(conn, :home, layout: false)
  end
end
