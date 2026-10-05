defmodule YellowDog.ManagementUI.Submission do
  @moduledoc "Keeps a request identity while an editor retries the same logical submission."

  import Phoenix.Component, only: [assign: 3]

  def prepare(socket, operation, params) do
    requests = Map.get(socket.assigns, :submissions, %{})

    key =
      case requests[operation] do
        {^params, key} -> key
        _ -> Ecto.UUID.generate()
      end

    socket = Phoenix.LiveView.clear_flash(socket, :info)
    {assign(socket, :submissions, Map.put(requests, operation, {params, key})), key}
  end
end
