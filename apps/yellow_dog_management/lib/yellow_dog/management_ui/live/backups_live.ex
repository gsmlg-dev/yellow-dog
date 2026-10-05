defmodule YellowDog.ManagementUI.BackupsLive do
  use YellowDog.ManagementUI, :live_view

  alias YellowDog.Management.{Backups, Domain}

  @poll_interval 2_000
  @deletable_states ~w(ready failed)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket),
      do: Phoenix.PubSub.subscribe(YellowDog.ManagementUI.PubSub, "management:backups")

    {:ok,
     socket
     |> assign(
       page_title: "Backups",
       backups: [],
       label: "",
       error: nil,
       notice: nil,
       confirm_delete: nil,
       restore_backup: nil,
       restore_confirmed: false,
       verifying: nil,
       verification: nil,
       poll_timer: nil
     )
     |> refresh()}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply,
     socket
     |> clear_verification()
     |> assign(
       page_title:
         if(socket.assigns.live_action == :restore, do: "Restore Backup", else: "Backups"),
       confirm_delete: nil,
       restore_backup: nil,
       error: nil,
       notice: nil
     )}
  end

  @impl true
  def handle_event("refresh", _params, socket), do: {:noreply, refresh(socket)}

  def handle_event("update_label", %{"label" => label}, socket)
      when is_binary(label) and byte_size(label) <= 128 do
    if valid_label?(label) do
      {:noreply, assign(socket, label: label, error: nil)}
    else
      failure(socket, "Label must be valid text of at most 128 bytes without null characters.")
    end
  end

  def handle_event("create_backup", %{"label" => label}, socket)
      when is_binary(label) and byte_size(label) <= 128 do
    if socket.assigns.live_action == :index and valid_label?(label) do
      socket = assign(socket, :label, label)

      case Domain.mutate("create_backup", %{"label" => label}, "operator", Ecto.UUID.generate()) do
        {:ok, _backup} ->
          {:noreply,
           socket
           |> clear_verification()
           |> assign(
             label: "",
             confirm_delete: nil,
             error: nil,
             notice: "Backup queued. Pending is not successful completion."
           )
           |> refresh()}

        {:error, error} ->
          failure(socket, "Could not queue backup: #{message(error)} Refresh and retry.")
      end
    else
      failure(
        socket,
        "Create is available on Backups with valid text of at most 128 bytes without null characters."
      )
    end
  end

  def handle_event(event, _params, socket) when event in ~w(create_backup update_label),
    do: failure(socket, "Label must be valid text of at most 128 bytes without null characters.")

  def handle_event("verify", params, socket) do
    with true <- socket.assigns.live_action == :index,
         {:ok, backup} <- selected(socket, params["id"], ["ready"]) do
      {:noreply, verify(socket, backup, :index)}
    else
      _invalid -> failure(socket, "Choose a ready backup to verify; refresh the list and retry.")
    end
  end

  def handle_event("dismiss_verify", _params, socket) do
    {:noreply, socket |> clear_verification() |> assign(error: nil)}
  end

  def handle_event("delete", params, socket) do
    with true <- socket.assigns.live_action == :index,
         {:ok, backup} <- selected(socket, params["id"], @deletable_states) do
      {:noreply, assign(socket, confirm_delete: backup, error: nil, notice: nil)}
    else
      _invalid -> failure(socket, "Choose a ready or failed backup to delete; refresh and retry.")
    end
  end

  def handle_event("cancel_delete", _params, socket),
    do: {:noreply, assign(socket, confirm_delete: nil, error: nil)}

  def handle_event("confirm_delete", params, socket) do
    backup = socket.assigns.confirm_delete

    with true <- socket.assigns.live_action == :index and not is_nil(backup),
         true <- matching_id?(params, field(backup, :id)),
         {:ok, current} <- selected(socket, field(backup, :id), @deletable_states) do
      case Domain.mutate(
             "delete_backup",
             %{"id" => field(current, :id)},
             "operator",
             Ecto.UUID.generate()
           ) do
        {:ok, _backup} ->
          {:noreply,
           socket
           |> clear_verification()
           |> assign(
             confirm_delete: nil,
             error: nil,
             notice: "Deletion queued. The package is not deleted until its state is deleted."
           )
           |> refresh()}

        {:error, error} ->
          failure(socket, "Could not queue deletion: #{message(error)} Refresh and retry.")
      end
    else
      _invalid -> failure(socket, "Deletion confirmation does not match an available backup.")
    end
  end

  def handle_event("select_restore", params, socket) do
    with true <- socket.assigns.live_action == :restore,
         {:ok, backup} <- selected(socket, params["id"], ["ready"]) do
      {:noreply, socket |> assign(:restore_backup, backup) |> verify(backup, :restore)}
    else
      _invalid ->
        socket = socket |> clear_verification() |> assign(:restore_backup, nil)
        failure(socket, "Choose a ready backup to prepare an offline restore; refresh and retry.")
    end
  end

  def handle_event("confirm_restore", params, socket) do
    with true <- socket.assigns.live_action == :restore,
         %{backup: backup, result: result} <- socket.assigns.verification,
         true <- field(result, :valid) == true,
         true <- socket.assigns.restore_backup == backup,
         true <- matching_id?(params, field(backup, :id)),
         {:ok, current} <- selected(socket, field(backup, :id), ["ready"]),
         true <- same_package?(backup, current) do
      {:noreply, assign(socket, restore_confirmed: true, error: nil)}
    else
      _invalid ->
        failure(
          assign(socket, :restore_confirmed, false),
          "A current, verified package must be selected before confirming offline restore."
        )
    end
  end

  def handle_event("cancel_restore", _params, socket) do
    {:noreply,
     socket
     |> clear_verification()
     |> assign(restore_backup: nil, error: nil, notice: nil)}
  end

  def handle_event(_event, _params, socket), do: failure(socket, "Invalid backup action.")

  @impl true
  def handle_info({:backup_updated, _id}, socket), do: {:noreply, refresh(socket)}

  def handle_info({:poll_backups, token}, %{assigns: %{poll_timer: {_timer, token}}} = socket),
    do: {:noreply, socket |> assign(:poll_timer, nil) |> refresh()}

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_async(
        {:verify_backup, token},
        outcome,
        %{assigns: %{verifying: %{token: token}}} = socket
      ) do
    %{backup: backup, purpose: purpose} = socket.assigns.verifying
    socket = assign(socket, :verifying, nil)

    with {:ok, {:ok, result}} <- outcome,
         true <- field(result, :valid) == true,
         {:ok, current} <- selected(socket, field(backup, :id), ["ready"]),
         true <- same_package?(backup, current) do
      {:noreply,
       assign(socket,
         verification: %{backup: current, result: result},
         restore_backup: if(purpose == :restore, do: current, else: nil),
         error: nil
       )}
    else
      {:ok, {:error, error}} ->
        failure(socket, "Verification failed: #{message(error)} Check the package and retry.")

      {:exit, _reason} ->
        failure(socket, "Verification interrupted. Check service logs and retry.")

      _invalid ->
        failure(socket, "Package is unavailable, changed, or invalid. Refresh and verify again.")
    end
  end

  def handle_async(_name, _outcome, socket), do: {:noreply, socket}

  defp verify(socket, backup, purpose) do
    socket = clear_verification(socket)
    token = make_ref()
    id = field(backup, :id)

    socket
    |> assign(
      verifying: %{token: token, backup: backup, purpose: purpose},
      error: nil,
      notice: nil
    )
    |> start_async({:verify_backup, token}, fn -> Backups.verify(id) end)
  end

  defp clear_verification(socket) do
    socket =
      case socket.assigns.verifying do
        %{token: token} -> cancel_async(socket, {:verify_backup, token})
        nil -> socket
      end

    assign(socket, verifying: nil, verification: nil, restore_confirmed: false)
  end

  defp selected(socket, id, states) when is_binary(id) do
    with true <- Enum.any?(socket.assigns.backups, &(field(&1, :id) == id)),
         {:ok, backup} <- Backups.get(id),
         true <- field(backup, :state) in states do
      {:ok, backup}
    else
      _invalid -> {:error, :unavailable}
    end
  end

  defp selected(_socket, _id, _states), do: {:error, :unavailable}

  defp matching_id?(params, id), do: not Map.has_key?(params, "id") or params["id"] == id

  defp valid_label?(label), do: String.valid?(label) and not String.contains?(label, <<0>>)

  defp same_package?(backup, current) do
    field(current, :state) == "ready" and field(backup, :id) == field(current, :id) and
      field(backup, :digest) == field(current, :digest)
  end

  defp refresh(socket) do
    socket = assign(socket, :backups, Backups.list())
    verification = socket.assigns.verification || socket.assigns.verifying

    socket =
      if verification &&
           not Enum.any?(socket.assigns.backups, &same_package?(verification.backup, &1)) do
        socket
        |> clear_verification()
        |> assign(
          error: "The selected package changed or is unavailable. Refresh and verify again."
        )
      else
        socket
      end

    active = Enum.any?(socket.assigns.backups, &(field(&1, :state) in ~w(pending deleting)))

    case {connected?(socket) and active, socket.assigns.poll_timer} do
      {true, nil} ->
        token = make_ref()
        timer = Process.send_after(self(), {:poll_backups, token}, @poll_interval)
        assign(socket, :poll_timer, {timer, token})

      {false, {timer, _token}} ->
        Process.cancel_timer(timer)
        assign(socket, :poll_timer, nil)

      _unchanged ->
        socket
    end
  end

  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp message(error) when is_map(error), do: field(error, :message) || inspect(error)
  defp message(error) when is_binary(error), do: error
  defp message(error), do: inspect(error)
  defp failure(socket, error), do: {:noreply, assign(socket, error: error, notice: nil)}
  defp display(nil), do: "—"
  defp display(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp display(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp display(value), do: to_string(value)

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :deletable_states, @deletable_states)

    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <section id={if @live_action == :restore, do: "backup-restore-page", else: "backups-page"}>
        <h1>{@page_title}</h1>
        <div class="management-actions">
          <.link navigate="/system/backups" class="btn btn-ghost">Backups</.link>
          <.link navigate="/system/backups/restore" class="btn btn-ghost">Restore Backup</.link>
          <button id="backups-refresh" phx-click="refresh" class="btn btn-ghost">Refresh</button>
        </div>
        <p :if={@error} id="backup-error" class="alert alert-error" role="alert">{@error}</p>
        <p :if={@notice} id="backup-notice" class="alert alert-info" role="status">{@notice}</p>

        <.card :if={@live_action == :index} title="Create Backup">
          <form id="backup-create-form" phx-change="update_label" phx-submit="create_backup">
            <label for="backup-label">Label (optional, at most 128 UTF-8 bytes)</label>
            <input id="backup-label" name="label" value={@label} maxlength="128" class="input" />
            <button class="btn btn-primary" phx-disable-with="Queueing...">Create Backup</button>
          </form>
          <p class="management-help">
            Creation runs as a durable job. Wait for ready before downloading or verifying.
          </p>
        </.card>

        <.card :if={@live_action == :restore} title="Offline Restore">
          <p class="alert alert-warning">
            Restore is destructive and requires downtime. Stop Management and its job workers first.
            This page only verifies package byte integrity; it never restores the live database.
          </p>
          <p id="backup-restore-capability" class="management-help">
            The offline restore CLI is not available yet. No executable restore command is offered.
            Package verification does not establish full recoverability.
          </p>
          <form id="backup-restore-form" phx-submit="select_restore">
            <label for="backup-restore-id">Choose a ready backup</label>
            <select id="backup-restore-id" name="id" class="select">
              <option value="">Select a backup</option>
              <option
                :for={backup <- @backups}
                :if={field(backup, :state) == "ready"}
                value={field(backup, :id)}
                selected={@restore_backup && field(@restore_backup, :id) == field(backup, :id)}
              >
                {field(backup, :label)} — {field(backup, :id)}
              </option>
            </select>
            <button class="btn btn-primary" phx-disable-with="Preparing...">Verify for Restore</button>
            <button type="button" phx-click="cancel_restore" class="btn btn-ghost">Cancel Restore</button>
          </form>
        </.card>

        <p :if={@verifying} id="backup-verifying" role="status">
          Verifying checksums and package contents for {field(@verifying.backup, :id)}...
        </p>
        <.card :if={@verification} title="Verified Package">
          <section id="backup-verification" data-backup-id={field(@verification.backup, :id)}>
            <p class="management-help">
              Verification checks byte integrity only: checksums and package structure.
              It does not prove full recoverability. No restore has been performed.
            </p>
            <dl>
              <dt>Verification level</dt><dd>{display(field(@verification.result, :level))}</dd>
              <dt>Backup ID</dt><dd>{field(@verification.backup, :id)}</dd>
              <dt>Package digest</dt><dd>{field(@verification.backup, :digest)}</dd>
              <dt>Dump digest</dt><dd>{field(@verification.result, :dump_digest)}</dd>
              <dt>Artifacts verified</dt><dd>{field(@verification.result, :artifact_count)}</dd>
              <dt>Package row count</dt><dd>{field(@verification.result, :row_count)}</dd>
            </dl>
            <button phx-click="dismiss_verify" class="btn btn-ghost">Dismiss Verification</button>
            <div :if={@live_action == :restore}>
              <p class="management-help">
                Offline restore replaces current Management data. Confirm that you understand the destructive operation and required downtime.
              </p>
              <button
                id="backup-confirm-restore"
                phx-click="confirm_restore"
                phx-value-id={field(@verification.backup, :id)}
                class="btn btn-warning"
              >I understand downtime and destructive restore</button>
              <section :if={@restore_confirmed} id="backup-restore-unavailable" role="status">
                <p>
                  Requirements acknowledged for verified package {field(@verification.backup, :id)}.
                </p>
                <p>
                  The offline restore CLI is not available yet. Do not stop Management expecting this page to restore data.
                </p>
                <p>
                  No restore has run from this page. Offline recovery remains unavailable until its implementation and validation are complete.
                </p>
              </section>
            </div>
          </section>
        </.card>

        <.modal
          :if={@confirm_delete}
          id="backup-delete-confirmation"
          title="Delete Backup?"
          show
          on_cancel={JS.push("cancel_delete")}
        >
          <p>
            Delete package {field(@confirm_delete, :id)} ({field(@confirm_delete, :label)})? This cannot be undone.
          </p>
          <:actions>
            <button phx-click="cancel_delete" class="btn btn-ghost">Cancel</button>
            <button
              id="backup-confirm-delete"
              phx-click="confirm_delete"
              phx-value-id={field(@confirm_delete, :id)}
              class="btn btn-error"
            >Queue Deletion</button>
          </:actions>
        </.modal>

        <.card title="Available Backups">
          <p :if={@backups == []} id="backups-empty" class="text-on-surface-variant">
            No backups found.
          </p>
          <.table
            :if={@backups != []}
            id="backups-list"
            rows={@backups}
          >
            <:col :let={backup} label="ID / Label">
              <span id={"backup-row-#{field(backup, :id)}"}>
                {field(backup, :id)} / {field(backup, :label)}
              </span>
            </:col>
            <:col :let={backup} label="State">{field(backup, :state)}</:col>
            <:col :let={backup} label="Created">{display(field(backup, :created_at))}</:col>
            <:col :let={backup} label="Completed">{display(field(backup, :completed_at))}</:col>
            <:col :let={backup} label="Size">{display(field(backup, :size))} bytes</:col>
            <:col :let={backup} label="Digest">{display(field(backup, :digest))}</:col>
            <:col :let={backup} label="Rows">{display(field(backup, :row_count))}</:col>
            <:col :let={backup} label="Error">
              <span :if={field(backup, :error)} class="text-error">{message(field(backup, :error))} Check service logs and retry.</span>
            </:col>
            <:action :let={backup}>
              <a
                :if={field(backup, :state) == "ready"}
                href={"/api/backups/#{URI.encode_www_form(field(backup, :id))}/download"}
                class="btn btn-ghost btn-sm"
              >Download</a>
              <button
                :if={@live_action == :index}
                phx-click="verify"
                phx-value-id={field(backup, :id)}
                disabled={field(backup, :state) != "ready" || not is_nil(@verifying)}
                class="btn btn-ghost btn-sm"
              >Verify</button>
              <button
                :if={@live_action == :index}
                phx-click="delete"
                phx-value-id={field(backup, :id)}
                disabled={field(backup, :state) not in @deletable_states}
                class="btn btn-error btn-sm"
              >Delete</button>
            </:action>
          </.table>
        </.card>
      </section>
    </Layouts.app>
    """
  end
end
