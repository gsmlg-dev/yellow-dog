defmodule YellowDog do
  @moduledoc """
  Documentation for `YellowDog`.
  """

  @banner_text File.read!("#{:code.priv_dir(:yellow_dog)}/banner.txt")

  @doc false
  def banner do
    @banner_text
  end

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {YellowDog.Config, YellowDog.Config.default_config()}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: YellowDog.Supervisor)
  end
end
