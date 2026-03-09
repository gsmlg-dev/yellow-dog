defmodule YellowDog.Console.ToolsLive.WhoisLive do
  @moduledoc """
  Whois lookup tool using the `gsmlg_whois` hex package.
  """
  use YellowDog.Console, :live_view

  alias YellowDog.Console.Layouts

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Whois Lookup",
       query: "",
       results: nil,
       error: nil,
       loading: false,
       task_ref: nil
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div class="max-w-4xl">
        <h1 class="text-2xl font-bold mb-4">Whois Lookup</h1>

        <form phx-submit="lookup" class="flex gap-2 mb-6">
          <input
            type="text"
            name="query"
            value={@query}
            placeholder="Enter domain or IP (e.g. example.com)"
            class="input flex-1"
            disabled={@loading}
            autofocus
          />
          <button
            type="submit"
            class="btn btn-primary"
            disabled={@loading}
            phx-disable-with="Looking up..."
          >
            <span :if={@loading} class="inline-block animate-spin rounded-full border-2 border-current border-t-transparent w-5 h-5" role="status"></span> Lookup
          </button>
        </form>

        <div :if={@error} class="alert alert-error mb-4">
          <span>{@error}</span>
        </div>

        <div
          :if={!@results && !@error && !@loading && @query == ""}
          class="text-center py-12 text-on-surface-variant"
        >
          Enter a domain or IP address to query WHOIS records
        </div>

        <div :if={@results} class="space-y-4">
          <div :for={{server, raw} <- @results}>
            <div class="mb-2">
              <span class="badge badge-info">{server}</span>
            </div>
            <div class="bg-surface-container rounded-lg p-4 overflow-x-auto font-mono text-sm">
              <pre class="whitespace-pre-wrap">{raw}</pre>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("lookup", %{"query" => query}, socket) do
    query = String.trim(query)

    if query == "" do
      {:noreply, assign(socket, results: nil, error: nil, query: "", loading: false)}
    else
      task = Task.async(fn -> GSMLG.Whois.lookup_raw(query) end)

      {:noreply,
       assign(socket, query: query, loading: true, error: nil, results: nil, task_ref: task.ref)}
    end
  end

  @impl true
  def handle_info({ref, result}, %{assigns: %{task_ref: ref}} = socket) do
    Process.demonitor(ref, [:flush])

    case result do
      {:ok, entries} ->
        {:noreply, assign(socket, results: entries, error: nil, loading: false, task_ref: nil)}

      {:error, reason} ->
        {:noreply,
         assign(socket,
           results: nil,
           error: format_error(reason),
           loading: false,
           task_ref: nil
         )}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{assigns: %{task_ref: ref}} = socket) do
    {:noreply,
     assign(socket,
       results: nil,
       error: "Lookup failed: #{inspect(reason)}",
       loading: false,
       task_ref: nil
     )}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp format_error(:timeout), do: "Connection timed out"
  defp format_error(:closed), do: "Connection closed unexpectedly"
  defp format_error(reason), do: "Lookup failed: #{inspect(reason)}"
end
