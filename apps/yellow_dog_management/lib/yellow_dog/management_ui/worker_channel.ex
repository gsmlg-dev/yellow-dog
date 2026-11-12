defmodule YellowDog.ManagementUI.WorkerChannel do
  @moduledoc """
  Authenticated Worker runtime channel on topic `"worker:<worker_id>"`.

  Join and every `"report"` re-authenticate through `WorkerConnections.connect/2`.
  The channel pushes `"target"` with `%{"target" => target | nil}` after join, when
  a newer target is confirmed and when a report observes a newer revision.
  """
  use Phoenix.Channel
  alias YellowDog.Management.{Domain, WorkerConnections}

  @impl true
  def join("worker:" <> id, report, %{assigns: %{worker_id: id}} = socket)
      when is_map(report) do
    case authenticate(report, socket) do
      {:ok, %{"target" => target}} ->
        :ok = Phoenix.PubSub.subscribe(YellowDog.ManagementUI.PubSub, "worker_target:" <> id)
        send(self(), {:push_target, target})
        {:ok, assign(socket, :pushed_revision, nil)}

      {:error, code} ->
        {:error, %{"code" => code}}
    end
  end

  def join(_topic, _report, _socket), do: {:error, %{"code" => "unauthorized"}}

  @impl true
  def handle_in("report", report, socket) when is_map(report) do
    case authenticate(report, socket) do
      {:ok, %{"target" => target}} ->
        socket =
          if newer?(target, socket.assigns.pushed_revision),
            do: push_target(socket, target),
            else: socket

        {:reply, {:ok, %{}}, socket}

      {:error, "unauthorized"} ->
        {:stop, :normal, {:error, %{"code" => "unauthorized"}}, socket}

      {:error, code} ->
        {:reply, {:error, %{"code" => code}}, socket}
    end
  end

  def handle_in(_event, _payload, socket),
    do: {:reply, {:error, %{"code" => "invalid_report"}}, socket}

  @impl true
  def handle_info({:push_target, target}, socket), do: {:noreply, push_target(socket, target)}

  def handle_info({:worker_target, id}, %{assigns: %{worker_id: id}} = socket) do
    target =
      case Domain.get_target(id) do
        {:ok, target} -> Map.take(target, ~w(revision digest plan))
        {:error, _} -> nil
      end

    {:noreply, push_target(socket, target)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp authenticate(%{"worker_id" => id} = report, %{assigns: %{worker_id: id}} = socket) do
    case WorkerConnections.connect(socket.assigns.worker_token.(), report) do
      {:ok, result} -> {:ok, result}
      {:error, %{code: code}} -> {:error, code}
    end
  end

  defp authenticate(_report, _socket), do: {:error, "unauthorized"}

  defp push_target(socket, target) do
    push(socket, "target", %{"target" => target})
    assign(socket, :pushed_revision, target && target["revision"])
  end

  defp newer?(%{"revision" => revision}, nil), do: is_integer(revision)
  defp newer?(%{"revision" => revision}, pushed), do: revision > pushed
  defp newer?(nil, _pushed), do: false
end
