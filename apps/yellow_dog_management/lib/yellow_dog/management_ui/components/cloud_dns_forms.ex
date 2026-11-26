defmodule YellowDog.ManagementUI.CloudDnsForms do
  @moduledoc false
  use YellowDog.ManagementUI, :html
  alias YellowDog.Management.CloudDns.Provider
  alias YellowDog.ManagementUI.CoreComponents

  attr :form, :map, default: nil

  def modal(assigns) do
    ~H"""
    <div
      :if={@form}
      id={@form.id}
      phx-hook="SchemaModal"
      phx-update="ignore"
      data-form={Jason.encode!(Map.drop(@form, [:id]))}
    />
    """
  end

  attr :cloud?, :boolean, required: true

  def zone_type_links(assigns) do
    ~H"""
    <nav aria-label="Authoritative zone type" class="management-actions">
      <.link
        navigate="/management/zones/new"
        class={["btn", if(@cloud?, do: "btn-outline", else: "btn-primary")]}
        aria-current={if !@cloud?, do: "page"}
      >Local</.link>
      <.link
        navigate="/management/zones/new/cloud"
        class={["btn", if(@cloud?, do: "btn-primary", else: "btn-outline")]}
        aria-current={if @cloud?, do: "page"}
      >Cloud-synced</.link>
    </nav>
    """
  end

  def provider_type_form do
    form(
      "Add Cloud Provider",
      %{
        "kind" =>
          options("Provider", [
            {"route53", Provider.label("route53")},
            {"cloudflare", Provider.label("cloudflare")}
          ])
      },
      %{}
    )
    |> Map.put(:choose_provider?, true)
  end

  def provider_form(kind, provider) do
    {required, optional} = Provider.credential_fields(kind)
    saved? = provider && is_nil(provider.profile)

    credentials =
      for field <- required ++ [optional], into: %{} do
        {field, credential(field, not is_nil(provider))}
      end

    fields =
      Map.put(credentials, "name", %{type: "string", title: "Name", minLength: 1, maxLength: 128})

    fields =
      if saved? do
        Map.put(fields, "remove_" <> optional, %{
          type: "boolean",
          title: "Remove saved " <> credential_label(optional)
        })
      else
        fields
      end

    action = if provider, do: "Edit", else: "Add"
    initial = if provider, do: %{name: provider.name}, else: %{}
    required_fields = if provider, do: ["name"], else: ["name" | required]

    form("#{action} #{Provider.label(kind)}", fields, initial, required_fields)
    |> Map.put(:kind, kind)
    |> Map.put(:textFields, ["name" | required] ++ [optional])
  end

  defp credential(field, editing?) do
    field_schema = %{
      type: "string",
      title: credential_label(field),
      writeOnly: true,
      maxLength: 8192
    }

    description =
      case {field, editing?} do
        {"account_id", true} ->
          "Needed to create Cloudflare zones. Leave blank to keep the current value."

        {"account_id", false} ->
          "Needed to create Cloudflare zones."

        {"session_token", true} ->
          "For temporary AWS credentials. Leave blank to keep the current value."

        {"session_token", false} ->
          "For temporary AWS credentials."

        {_, true} ->
          "Leave blank to keep the current value."

        {_, false} ->
          nil
      end

    if description, do: Map.put(field_schema, :description, description), else: field_schema
  end

  defp credential_label("access_key_id"), do: "AWS Access Key ID"
  defp credential_label("secret_access_key"), do: "AWS Secret Access Key"
  defp credential_label("session_token"), do: "AWS Session Token"
  defp credential_label("api_token"), do: "Cloudflare API Token"
  defp credential_label("account_id"), do: "Cloudflare Account ID"

  attr :providers, :list, required: true
  attr :provider_id, :string, required: true
  attr :remote_zones, :any, required: true
  attr :error, :string, required: true

  def import_modal(assigns) do
    options =
      case assigns.remote_zones do
        {:ok, zones} -> zone_options(zones)
        _ -> []
      end

    assigns = assign(assigns, options: options, providers: provider_options(assigns.providers))

    ~H"""
    <CoreComponents.modal
      id="cloud-dns-import-modal"
      title="Import cloud zone"
      show
      on_cancel={JS.push("close_modal")}
    >
      <form id="cloud-dns-import-form" phx-submit="import_cloud_zone">
        <label class="management-field" for="cloud-dns-import-provider">
          <span>Cloud Provider</span>
          <select
            id="cloud-dns-import-provider"
            name="provider_id"
            class="select"
            phx-change="select_import_provider"
            required
          >
            <option value="">Select a provider</option>
            {Phoenix.HTML.Form.options_for_select(@providers, @provider_id)}
          </select>
        </label>
        <label class="management-field" for="cloud-dns-import-zone">
          <span>Cloud zone</span>
          <select
            id="cloud-dns-import-zone"
            name="remote_id"
            class="select"
            disabled={@options == []}
            required
          >
            <option value="">Select a cloud zone</option>
            {Phoenix.HTML.Form.options_for_select(@options, nil)}
          </select>
        </label>
        <p :if={@remote_zones == :loading} role="status">Loading cloud zones…</p>
        <p :if={@remote_zones == {:ok, []}} role="status">
          No cloud zones found.
        </p>
        <p :if={@error} role="alert" class="alert alert-error">{@error}</p>
        <div class="modal-action">
          <button
            :if={match?({:error, _}, @remote_zones)}
            type="button"
            class="btn btn-outline"
            phx-click="retry_import_provider"
          >Retry</button>
          <button type="button" class="btn btn-ghost" phx-click="close_modal">Cancel</button>
          <button type="submit" class="btn btn-primary" disabled={@options == []}>Import</button>
        </div>
      </form>
    </CoreComponents.modal>
    """
  end

  def create_binding_form(providers, zones) do
    fields = %{
      "provider_id" =>
        options(
          "Cloud Provider",
          Enum.map(provider_options(providers), fn {label, id} -> {id, label} end)
        ),
      "zone_id" => options("Local zone", Enum.map(zones, &{&1.id, &1.name}))
    }

    form("Create cloud zone from local zone", fields, %{})
  end

  defp provider_options(providers),
    do: Enum.map(providers, &{"#{&1.name} · #{Provider.label(&1.kind)}", &1.id})

  defp zone_options(zones) do
    name_counts = Enum.frequencies_by(zones, & &1.name)

    Enum.map(zones, fn %{id: id, name: name} ->
      label = if name_counts[name] > 1, do: "#{name} (#{id})", else: name
      {label, id}
    end)
  end

  def conflicts_form(rows) do
    fields =
      rows
      |> Enum.with_index()
      |> Enum.filter(fn {row, _index} -> row.state == :conflict end)
      |> Map.new(fn {row, index} ->
        title = "#{elem(row.key, 0)} #{elem(row.key, 1)}"

        {Integer.to_string(index),
         options(title, [{"local", "Keep local"}, {"remote", "Use cloud"}])}
      end)

    form("Resolve record conflicts", fields, %{})
  end

  defp options(title, options) do
    %{
      type: "string",
      title: title,
      enum: Enum.map(options, &elem(&1, 0)),
      "x-widget": "select",
      "x-options": Enum.map(options, fn {value, label} -> %{value: value, label: label} end)
    }
  end

  defp form(title, fields, initial, required \\ nil) do
    %{
      id: "cloud-dns-form-#{Ecto.UUID.generate()}",
      title: title,
      schema: %{
        type: "object",
        additionalProperties: false,
        properties: fields,
        required: required || Map.keys(fields)
      },
      initial: initial
    }
  end
end
