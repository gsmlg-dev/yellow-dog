defmodule YellowDog.Console.NetbootLive.TftpLive do
  @moduledoc "TFTP server status — server config, file browser, active transfers."
  use YellowDog.Console, :live_view

  import YellowDog.Console.ServiceHelper

  alias YellowDog.Console.Layouts

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, "netboot:tftp")
    end

    {:ok,
     socket
     |> assign(page_title: "TFTP Server")
     |> load_data()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div class="space-y-6">
        <div>
          <h1 class="text-4xl font-bold">TFTP Server</h1>
          <p class="mt-2 text-base-content/70">
            Boot file serving via TFTP protocol
          </p>
        </div>

        <div class="stats stats-vertical sm:stats-horizontal shadow w-full">
          <div class="stat">
            <div class="stat-title">Status</div>
            <div :if={@status.running} class="stat-value text-success">Running</div>
            <div :if={!@status.running} class="stat-value text-error">Stopped</div>
          </div>
          <div class="stat">
            <div class="stat-title">Port</div>
            <div class="stat-value font-mono">{@status.port}</div>
          </div>
          <div class="stat">
            <div class="stat-title">Files Indexed</div>
            <div class="stat-value">{@status.file_count}</div>
          </div>
          <div class="stat">
            <div class="stat-title">Active Transfers</div>
            <div class="stat-value">{@status.active_transfers}</div>
          </div>
        </div>

        <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
          <.card>
            <h2 class="card-title mb-4">Configuration</h2>
            <div class="space-y-2">
              <div class="flex justify-between">
                <span class="text-base-content/70">Root Directory</span>
                <span class="font-mono text-sm">{@status.root_dir}</span>
              </div>
              <div class="flex justify-between">
                <span class="text-base-content/70">Listen Port</span>
                <span class="font-mono">{@status.port}</span>
              </div>
            </div>
            <div class="mt-4">
              <button phx-click="rescan" class="btn btn-outline btn-sm">
                Rescan Files
              </button>
            </div>
          </.card>

          <.card>
            <h2 class="card-title mb-4">File Browser</h2>
            <div :if={@file_tree == []} class="text-base-content/50">
              No files found in TFTP root
            </div>
            <div :if={@file_tree != []} class="text-sm">
              <.file_tree_node :for={node <- @file_tree} node={node} />
            </div>
          </.card>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp file_tree_node(%{node: %{type: :directory}} = assigns) do
    ~H"""
    <details class="ml-2">
      <summary class="cursor-pointer hover:text-primary py-0.5">
        {@node.name}/
      </summary>
      <div class="ml-2 border-l border-base-300 pl-2">
        <.file_tree_node :for={child <- @node.children} node={child} />
      </div>
    </details>
    """
  end

  defp file_tree_node(%{node: %{type: :file}} = assigns) do
    ~H"""
    <div class="ml-2 py-0.5 flex justify-between">
      <span class="font-mono">{@node.name}</span>
      <span class="text-base-content/50">{format_size(@node.size)}</span>
    </div>
    """
  end

  @impl true
  def handle_event("rescan", _params, socket) do
    safe_call(
      YellowDog.Netboot.TFTP.FileIndex,
      fn ->
        root = YellowDog.Netboot.TFTP.Server.root_dir()
        YellowDog.Netboot.TFTP.FileIndex.scan(root)
      end,
      :ok
    )

    {:noreply, socket |> put_flash(:info, "File index rescanned") |> load_data()}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, load_data(socket)}

  defp load_data(socket) do
    status =
      safe_call(
        YellowDog.Netboot.TFTP.Server,
        fn ->
          YellowDog.Netboot.TFTP.Server.status()
        end,
        %{running: false, port: 69, file_count: 0, active_transfers: 0, root_dir: "-"}
      )

    tree =
      safe_call(
        YellowDog.Netboot.Asset.Store,
        fn ->
          YellowDog.Netboot.Asset.Store.file_tree()
        end,
        []
      )

    socket
    |> assign(:status, status)
    |> assign(:file_tree, tree)
  end

  defp format_size(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_size(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_size(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"
end
