defmodule YellowDog.ManagementUI.CloudProvidersLive do
  use YellowDog.ManagementUI, {:live_view, log: false}

  alias YellowDog.Management.CloudDns
  alias YellowDog.Management.CloudDns.Provider
  alias YellowDog.ManagementUI.CloudDnsForms

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: "Cloud Providers", form: nil, editing: nil) |> reload()}
  end

  @impl true
  def handle_event("new", _, socket) do
    {:noreply, assign(socket, form: CloudDnsForms.provider_type_form(), editing: nil)}
  end

  def handle_event("edit", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.providers, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      provider ->
        {:noreply,
         assign(socket,
           form: CloudDnsForms.provider_form(provider.kind, provider),
           editing: provider
         )}
    end
  end

  def handle_event("close_modal", _, socket), do: {:noreply, clear(socket)}

  def handle_event(
        "submit_modal",
        %{"kind" => kind},
        %{assigns: %{form: %{choose_provider?: true}}} = socket
      )
      when kind in ["route53", "cloudflare"] do
    {:reply, %{}, assign(socket, form: CloudDnsForms.provider_form(kind, nil))}
  end

  def handle_event("submit_modal", values, %{assigns: %{form: %{kind: kind} = form}} = socket)
      when is_map(values) do
    caller = socket.assigns.caller
    values = values |> Map.take(Map.keys(form.schema.properties)) |> Map.put("kind", kind)

    result =
      case socket.assigns.editing do
        nil -> CloudDns.add_provider(caller, values)
        provider -> CloudDns.update_provider(caller, provider, values)
      end

    case result do
      {:ok, _provider} ->
        {:reply, %{}, socket |> clear() |> reload() |> put_flash(:info, "Cloud Provider saved")}

      {:error, reason} ->
        {:reply, %{error: error(reason)}, socket}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case CloudDns.delete_provider(socket.assigns.caller, id) do
      {:ok, _provider} ->
        {:noreply, socket |> reload() |> put_flash(:info, "Cloud Provider deleted")}

      {:error, _reason} ->
        {:noreply,
         put_flash(socket, :error, "Unlink this provider from its zones before deleting it.")}
    end
  end

  def handle_event(_, _, socket), do: {:noreply, socket}

  defp clear(socket), do: assign(socket, form: nil, editing: nil)

  defp reload(socket) do
    case CloudDns.providers(socket.assigns.caller) do
      {:ok, providers} -> assign(socket, :providers, providers)
      {:error, _reason} -> assign(socket, :providers, [])
    end
  end

  defp error(:stale_provider), do: "The provider changed. Reopen it and try again."

  defp error(:provider_in_use),
    do: "Unlink the provider from its zones before changing its type."

  defp error(%Ecto.Changeset{errors: errors}) do
    Enum.map_join(errors, ". ", fn {field, {message, _}} ->
      "#{Phoenix.Naming.humanize(field)} #{message}"
    end)
  end

  defp error(_), do: "The provider could not be saved."

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app caller={@caller} flash={@flash} current_path={@current_path}>
      <h1>Cloud Providers</h1>
      <.card title="DNS providers">
        <div class="management-actions">
          <button id="cloud-provider-new" type="button" phx-click="new" class="btn btn-primary">Add Cloud Provider</button>
        </div>
        <p :if={@providers == []}>No cloud providers configured.</p>
        <div :if={@providers != []} class="overflow-x-auto">
          <table class="table">
            <thead>
              <tr>
                <th>Name</th><th>Provider</th><th>Authentication</th><th>Actions</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={provider <- @providers} id={"cloud-provider-#{provider.id}"}>
                <td>{provider.name}</td><td>{Provider.label(provider.kind)}</td><td>
                  {if provider.profile,
                    do: "Environment profile (#{provider.profile})",
                    else: "Configured"}
                </td>
                <td>
                  <button
                    type="button"
                    phx-click="edit"
                    phx-value-id={provider.id}
                    class="btn btn-outline"
                  >Edit</button>
                  <button
                    type="button"
                    phx-click="delete"
                    phx-value-id={provider.id}
                    disabled={provider.bound?}
                    data-confirm="Delete this cloud provider?"
                    class="btn btn-ghost"
                  >Delete</button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </.card>
      <CloudDnsForms.modal form={@form} />
    </Layouts.app>
    """
  end
end
