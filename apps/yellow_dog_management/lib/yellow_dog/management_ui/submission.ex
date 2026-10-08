defmodule YellowDog.ManagementUI.Submission do
  @moduledoc "Keeps pending requests stable and retires events from completed editor intents."

  import Phoenix.Component, only: [assign: 3]

  def new(socket) do
    socket
    |> assign(:submission_id, Ecto.UUID.generate())
    |> assign(:submission_previous, nil)
    |> assign(:submissions, %{})
  end

  def current?(socket, token, edited_operation \\ nil) do
    is_binary(token) and
      (token == socket.assigns.submission_id or
         case socket.assigns.submission_previous do
           {^token, operations, _requests} -> edited_operation in operations
           _ -> false
         end)
  end

  def edited?(socket, token) do
    case socket.assigns.submission_previous do
      {^token, _operations, _requests} when is_binary(token) -> true
      _ -> false
    end
  end

  def edit(socket, operations) do
    requests = Map.get(socket.assigns, :submissions, %{})

    if Enum.any?(operations, &Map.has_key?(requests, &1)) do
      socket
      |> retire(operations)
      |> assign(:submissions, Map.drop(requests, operations))
    else
      socket
    end
  end

  def prepare(socket, operation, params, token) do
    socket = Phoenix.LiveView.clear_flash(socket, :info)

    case socket.assigns.submission_previous do
      {^token, _operations, %{^operation => {^params, key}}} ->
        # Replay the retired request without making it the current intent's request.
        {socket, key}

      _ ->
        prepare_current(socket, operation, params)
    end
  end

  defp prepare_current(socket, operation, params) do
    requests = Map.get(socket.assigns, :submissions, %{})

    {socket, key} =
      case requests[operation] do
        {^params, key} -> {socket, key}
        nil -> {socket, Ecto.UUID.generate()}
        _ -> {retire(socket, [operation]), Ecto.UUID.generate()}
      end

    {assign(socket, :submissions, Map.put(requests, operation, {params, key})), key}
  end

  # One previous editor token allows a submit already queued behind its phx-change.
  # Callers permit it only for that editor's current retained input, never on resets.
  defp retire(socket, operations) do
    socket
    |> assign(:submission_previous, {
      socket.assigns.submission_id,
      operations,
      Map.take(socket.assigns.submissions, operations)
    })
    |> assign(:submission_id, Ecto.UUID.generate())
  end
end
