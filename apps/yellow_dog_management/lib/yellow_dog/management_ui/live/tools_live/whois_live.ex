defmodule YellowDog.ManagementUI.ToolsLive.WhoisLive do
  @moduledoc """
  Whois lookup tool using the `gsmlg_whois` hex package.
  """
  use YellowDog.ManagementUI, :live_view

  alias YellowDog.ManagementUI.Layouts

  @lookup_deadline_ms 30_000

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Whois Lookup",
       query: "",
       results: nil,
       error: nil,
       loading: false,
       lookup_token: nil,
       lookup_timer: nil
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div class="max-w-4xl">
        <h1 class="text-2xl font-bold mb-4">Whois Lookup</h1>

        <form
          id="whois-lookup-form"
          phx-submit="lookup"
          phx-hook="ResetForm"
          class="flex gap-2 mb-6"
        >
          <input
            type="text"
            name="query"
            aria-label="Domain or IP address"
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
            <span
              :if={@loading}
              class="inline-block animate-spin rounded-full border-2 border-current border-t-transparent w-5 h-5"
              role="status"
            ></span>
            Lookup
          </button>
        </form>

        <div :if={@error} id="whois-lookup-error" class="alert alert-error mb-4">
          <span>{@error}</span>
        </div>

        <div
          :if={!@results && !@error && !@loading && @query == ""}
          class="text-center py-12 text-on-surface-variant"
        >
          Enter a domain or IP address to query WHOIS records
        </div>

        <div :if={@results} id="whois-lookup-result" class="space-y-4">
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
      {:noreply,
       socket
       |> cancel_async(:whois_lookup)
       |> clear_deadline()
       |> assign(results: nil, error: nil, query: "", loading: false)
       |> push_event("reset_form", %{id: "whois-lookup-form"})}
    else
      lookup =
        Application.get_env(:yellow_dog_management, :whois_lookup, &GSMLG.Whois.lookup_raw/1)

      token = make_ref()

      deadline =
        Application.get_env(
          :yellow_dog_management,
          :whois_lookup_deadline_ms,
          @lookup_deadline_ms
        )

      timer = Process.send_after(self(), {:whois_deadline, token}, deadline)

      {:noreply,
       socket
       |> cancel_async(:whois_lookup)
       |> clear_deadline()
       |> assign(
         query: query,
         loading: true,
         error: nil,
         results: nil,
         lookup_token: token,
         lookup_timer: timer
       )
       # TODO(upstream): gsmlg-dev/gsmlg_umbrella#9
       # WORKAROUND(upstream): gsmlg-dev/gsmlg_umbrella#9
       |> start_async(:whois_lookup, fn -> lookup.(query) end)}
    end
  end

  @impl true
  def handle_async(:whois_lookup, _result, %{assigns: %{loading: false}} = socket) do
    {:noreply, socket}
  end

  def handle_async(:whois_lookup, {:ok, {:ok, entries}}, socket) do
    {:noreply, socket |> clear_deadline() |> assign(results: entries, error: nil, loading: false)}
  end

  def handle_async(:whois_lookup, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> clear_deadline()
     |> assign(results: nil, error: format_error(reason), loading: false)}
  end

  def handle_async(:whois_lookup, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> clear_deadline()
     |> assign(
       results: nil,
       error: "Lookup failed: #{inspect(reason)}",
       loading: false
     )}
  end

  @impl true
  def handle_info(
        {:whois_deadline, token},
        %{assigns: %{lookup_token: token, loading: true}} = socket
      ) do
    {:noreply,
     socket
     |> cancel_async(:whois_lookup)
     |> clear_deadline()
     |> assign(results: nil, error: "Lookup deadline exceeded; try again", loading: false)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    cancel_async(socket, :whois_lookup)
    if socket.assigns.lookup_timer, do: Process.cancel_timer(socket.assigns.lookup_timer)
    :ok
  end

  defp clear_deadline(socket) do
    if socket.assigns.lookup_timer, do: Process.cancel_timer(socket.assigns.lookup_timer)
    assign(socket, lookup_timer: nil, lookup_token: nil)
  end

  defp format_error(:timeout), do: "Connection timed out"
  defp format_error(:closed), do: "Connection closed unexpectedly"
  defp format_error(reason), do: "Lookup failed: #{inspect(reason)}"
end
