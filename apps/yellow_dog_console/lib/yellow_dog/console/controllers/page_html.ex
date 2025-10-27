defmodule YellowDog.Console.PageHTML do
  @moduledoc """
  This module contains pages rendered by PageController.
  """
  use YellowDog.Console, :html

  embed_templates "page_html/*"
end
