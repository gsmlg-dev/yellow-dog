defmodule YellowDog.ManagementUI.CertificatesLive do
  use YellowDog.ManagementUI, {:live_view, log: false}

  alias YellowDog.Management.DnsCertificates

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Certificate management",
       certificates: DnsCertificates.list(),
       selected: nil,
       error: nil,
       references: []
     )}
  end

  @impl true
  def handle_event("edit", %{"id" => id}, socket) do
    {:noreply,
     assign(socket,
       selected: Enum.find(socket.assigns.certificates, &(&1.id == id)),
       error: nil,
       references: []
     )}
  end

  def handle_event("cancel", _params, socket), do: {:noreply, reset(socket)}

  def handle_event("save", %{"certificate" => params}, socket) do
    result =
      case socket.assigns.selected do
        nil ->
          DnsCertificates.create(socket.assigns.caller, params)

        %{id: id, revision: revision} ->
          DnsCertificates.replace(socket.assigns.caller, id, revision, params)
      end

    case result do
      {:ok, _metadata} -> {:noreply, socket |> reset() |> put_flash(:info, "Certificate saved")}
      {:error, error} -> {:noreply, display_error(socket, error)}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.certificates, &(&1.id == id)) do
      %{revision: revision} ->
        case DnsCertificates.delete(socket.assigns.caller, id, revision) do
          {:ok, :ok} -> {:noreply, socket |> reset() |> put_flash(:info, "Certificate deleted")}
          {:error, error} -> {:noreply, display_error(socket, error)}
        end

      nil ->
        {:noreply, display_error(socket, %{code: "not_found"})}
    end
  end

  defp reset(socket) do
    assign(socket,
      certificates: DnsCertificates.list(),
      selected: nil,
      error: nil,
      references: []
    )
  end

  defp display_error(socket, %Ecto.Changeset{} = changeset) do
    message =
      Enum.map_join(changeset.errors, ". ", fn {field, {message, options}} ->
        label =
          %{name: "Name", certificate_pem: "Certificate chain", private_key_pem: "Private key"}[
            field
          ]

        label <>
          " " <>
          Enum.reduce(options, message, fn {key, value}, text ->
            String.replace(text, "%{" <> Atom.to_string(key) <> "}", to_string(value))
          end)
      end)

    assign(socket, error: message, references: [])
  end

  defp display_error(socket, %{code: "certificate_in_use", references: refs}) do
    assign(socket,
      error: "This certificate is still referenced by DNS settings.",
      references: refs
    )
  end

  defp display_error(socket, _error) do
    socket
    |> reset()
    |> assign(
      :error,
      "The certificate operation could not be completed. Check the current list and retry."
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app caller={@caller} flash={@flash} current_path={@current_path}>
      <h1>Certificate management</h1>
      <.card title="DNS certificates">
        <p :if={@certificates == []}>No certificates configured.</p>
        <div :if={@certificates != []} class="management-records">
          <table id="dns-certificates" class="table">
            <thead>
              <tr>
                <th>Name</th><th>Revision</th><th>Actions</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={certificate <- @certificates} id={"certificate-#{certificate.id}"}>
                <td>{certificate.name}</td><td>{certificate.revision}</td>
                <td>
                  <button
                    type="button"
                    class="btn btn-outline"
                    phx-click="edit"
                    phx-value-id={certificate.id}
                  >Replace</button>
                  <button
                    type="button"
                    class="btn btn-outline"
                    phx-click="delete"
                    phx-value-id={certificate.id}
                    data-confirm={"Delete certificate #{certificate.name}?"}
                  >Delete</button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </.card>
      <.card title={if @selected, do: "Replace certificate", else: "Add certificate"}>
        <p :if={@error} role="alert" class="text-error">{@error}</p>
        <ul :if={@references != []} id="certificate-references">
          <li :for={ref <- @references}>{ref.worker_id} · {String.upcase(ref.protocol)}</li>
        </ul>
        <.form
          for={%{}}
          as={:certificate}
          id={if @selected, do: "certificate-form-#{@selected.id}", else: "certificate-form"}
          phx-submit="save"
          class="grid gap-4"
        >
          <label class="form-control">
            <span class="label">Name</span>
            <input
              class="input input-bordered"
              name="certificate[name]"
              value={@selected && @selected.name}
              required
            />
          </label>
          <label class="form-control">
            <span class="label">Certificate chain (PEM)</span>
            <textarea
              class="textarea textarea-bordered"
              name="certificate[certificate_pem]"
              required
              rows="4"
            ></textarea>
          </label>
          <label class="form-control">
            <span class="label">Private key (PEM)</span>
            <textarea
              class="textarea textarea-bordered"
              name="certificate[private_key_pem]"
              required
              rows="4"
            ></textarea>
          </label>
          <div class="flex flex-wrap gap-2">
            <button type="submit" class="btn btn-primary" phx-disable-with="Saving…">Save certificate</button>
            <button :if={@selected} type="button" class="btn btn-outline" phx-click="cancel">Cancel</button>
          </div>
        </.form>
      </.card>
    </Layouts.app>
    """
  end
end
