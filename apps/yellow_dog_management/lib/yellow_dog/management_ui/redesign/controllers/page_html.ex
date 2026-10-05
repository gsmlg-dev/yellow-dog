defmodule YellowDog.ManagementUI.Redesign.PageHTML do
  @moduledoc """
  This module contains pages rendered by PageController.
  """
  use YellowDog.ManagementUI.Redesign, :html

  embed_templates "page_html/*"
end
