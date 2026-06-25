defmodule YellowDog.Console.CloudDnsLive do
  @moduledoc """
  Cloud DNS provider connector setup under System > Provider.
  """

  use YellowDog.Console, :live_view

  alias YellowDog.Console.Layouts
  alias YellowDog.Store.Provider

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Cloud DNS",
       connectors: [],
       connector_modal_open?: false,
       connector_form: to_form(default_connector_form(), as: :connector),
       form_errors: %{}
     )}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, load_connectors(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div class="max-w-7xl space-y-6">
        <div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
          <div>
            <h1 class="text-3xl font-bold">Cloud DNS</h1>
            <p class="text-sm text-on-surface-variant mt-1">
              Provider connectors for authoritative zone sync
            </p>
          </div>
          <div class="flex items-center gap-2">
            <button phx-click="refresh" class="btn btn-ghost btn-sm">
              <.dm_mdi name="refresh" class="h-5 w-5" /> Refresh
            </button>
            <button phx-click="open_add_connector" class="btn btn-primary btn-sm">
              <.dm_mdi name="plus" class="h-5 w-5" /> Add Cloud DNS
            </button>
          </div>
        </div>

        <div class="card bg-surface shadow-xl">
          <div class="card-body">
            <div class="flex items-center justify-between gap-3">
              <h2 class="card-title text-lg">Connectors</h2>
              <span class="badge badge-ghost">{length(@connectors)}</span>
            </div>

            <%= if @connectors == [] do %>
              <div class="text-center py-12 text-on-surface-variant">
                <.dm_mdi name="cloud-off-outline" class="w-12 h-12 mx-auto mb-3 opacity-50" />
                <p>No Cloud DNS connectors configured.</p>
                <button phx-click="open_add_connector" class="btn btn-primary btn-sm mt-4">
                  <.dm_mdi name="plus" class="h-5 w-5" /> Add Cloud DNS
                </button>
              </div>
            <% else %>
              <div class="overflow-x-auto mt-3">
                <table class="table table-striped">
                  <thead>
                    <tr>
                      <th>Name</th>
                      <th>Provider</th>
                      <th>Status</th>
                      <th>Credentials</th>
                      <th class="text-right">Actions</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={connector <- @connectors}>
                      <td class="font-mono font-semibold">{connector.name}</td>
                      <td>{provider_label(connector.type)}</td>
                      <td>
                        <span class={"badge badge-sm #{if connector.enabled, do: "badge-success", else: "badge-ghost"}"}>
                          {if connector.enabled, do: "Enabled", else: "Disabled"}
                        </span>
                      </td>
                      <td class="font-mono text-xs text-on-surface-variant">
                        {masked_credentials(connector)}
                      </td>
                      <td class="text-right">
                        <button
                          type="button"
                          class="btn btn-ghost btn-sm text-error"
                          phx-click="delete_connector"
                          phx-value-name={connector.name}
                          data-confirm={"Delete #{connector.name}?"}
                        >
                          <.dm_mdi name="delete" class="w-4 h-4" />
                        </button>
                      </td>
                    </tr>
                  </tbody>
                </table>
              </div>
            <% end %>
          </div>
        </div>

        <.connector_modal
          :if={@connector_modal_open?}
          form={@connector_form}
          errors={@form_errors}
        />
      </div>
    </Layouts.app>
    """
  end

  defp connector_modal(assigns) do
    ~H"""
    <div id="cloud-dns-modal" class="modal modal-open">
      <div class="modal-box max-w-2xl">
        <div class="flex items-start justify-between gap-3">
          <div>
            <h2 class="text-xl font-semibold">Add Cloud DNS</h2>
            <p class="text-sm text-on-surface-variant mt-1">
              Configure one provider connector for zone mirror bindings.
            </p>
          </div>
          <button
            type="button"
            class="btn btn-ghost btn-sm btn-square"
            aria-label="Close"
            phx-click="close_connector_modal"
          >
            <.dm_mdi name="close" class="h-5 w-5" />
          </button>
        </div>

        <.form
          for={@form}
          id="cloud-dns-form"
          phx-change="validate_connector"
          phx-submit="save_connector"
          class="space-y-4 mt-5"
        >
          <div class="form-group">
            <label class="form-label font-semibold">Provider</label>
            <select name="connector[provider]" class="select w-full">
              <option value="cloudflare" selected={selected_provider(@form) == "cloudflare"}>
                Cloudflare DNS
              </option>
              <option value="route53" selected={selected_provider(@form) == "route53"}>
                AWS Route 53
              </option>
            </select>
          </div>

          <div class="form-group">
            <label class="form-label font-semibold">Connector Name</label>
            <input
              type="text"
              name={"#{@form.name}[name]"}
              value={@form[:name].value}
              class={"input w-full font-mono #{if @errors[:name], do: "input-error"}"}
              placeholder={default_name(selected_provider(@form))}
              required
            />
            <.field_error error={@errors[:name]} />
          </div>

          <%= if selected_provider(@form) == "cloudflare" do %>
            <div class="form-group">
              <label class="form-label font-semibold">API Token</label>
              <input
                type="password"
                name={"#{@form.name}[api_token]"}
                value={@form[:api_token].value}
                class={"input w-full font-mono #{if @errors[:api_token], do: "input-error"}"}
                autocomplete="new-password"
                required
              />
              <.field_error error={@errors[:api_token]} />
            </div>
            <div class="form-group">
              <label class="form-label font-semibold">Account ID</label>
              <input
                type="text"
                name={"#{@form.name}[account_id]"}
                value={@form[:account_id].value}
                class="input w-full font-mono"
              />
            </div>
          <% else %>
            <div class="grid gap-4 md:grid-cols-2">
              <div class="form-group">
                <label class="form-label font-semibold">Access Key ID</label>
                <input
                  type="text"
                  name={"#{@form.name}[access_key_id]"}
                  value={@form[:access_key_id].value}
                  class={"input w-full font-mono #{if @errors[:access_key_id], do: "input-error"}"}
                  autocomplete="off"
                  required
                />
                <.field_error error={@errors[:access_key_id]} />
              </div>
            </div>
            <div class="form-group">
              <label class="form-label font-semibold">Secret Access Key</label>
              <input
                type="password"
                name={"#{@form.name}[secret_access_key]"}
                value={@form[:secret_access_key].value}
                class={"input w-full font-mono #{if @errors[:secret_access_key], do: "input-error"}"}
                autocomplete="new-password"
                required
              />
              <.field_error error={@errors[:secret_access_key]} />
            </div>
          <% end %>

          <label class="label cursor-pointer justify-start gap-3 p-0">
            <input type="hidden" name={"#{@form.name}[enabled]"} value="false" />
            <input
              type="checkbox"
              name={"#{@form.name}[enabled]"}
              value="true"
              class="checkbox checkbox-primary"
              checked={enabled?(@form[:enabled].value)}
            />
            <span class="label-text font-semibold">Enabled</span>
          </label>

          <div class="modal-action">
            <button type="button" class="btn btn-ghost" phx-click="close_connector_modal">
              Cancel
            </button>
            <button type="submit" class="btn btn-primary" phx-disable-with="Saving...">
              <.dm_mdi name="content-save" class="w-4 h-4" /> Save Connector
            </button>
          </div>
        </.form>
      </div>
      <div class="modal-backdrop" phx-click="close_connector_modal"></div>
    </div>
    """
  end

  defp field_error(assigns) do
    ~H"""
    <span :if={@error} class="helper-text text-error">{@error}</span>
    """
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, load_connectors(socket)}
  end

  @impl true
  def handle_event("open_add_connector", _params, socket) do
    {:noreply,
     socket
     |> assign(:connector_modal_open?, true)
     |> assign(:connector_form, to_form(default_connector_form(), as: :connector))
     |> assign(:form_errors, %{})}
  end

  @impl true
  def handle_event("close_connector_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:connector_modal_open?, false)
     |> assign(:connector_form, to_form(default_connector_form(), as: :connector))
     |> assign(:form_errors, %{})}
  end

  @impl true
  def handle_event("validate_connector", %{"connector" => params}, socket) do
    {:noreply,
     socket
     |> assign(:connector_modal_open?, true)
     |> assign(:connector_form, to_form(connector_form_data(params), as: :connector))
     |> assign(:form_errors, %{})}
  end

  @impl true
  def handle_event("save_connector", %{"connector" => params}, socket) do
    params = connector_form_data(params)
    save_connector(socket, connector_type(params), params)
  end

  @impl true
  def handle_event("save_cloudflare", %{"cloudflare" => params}, socket) do
    save_connector(socket, :cloudflare, params)
  end

  @impl true
  def handle_event("save_route53", %{"route53" => params}, socket) do
    save_connector(socket, :route53, params)
  end

  @impl true
  def handle_event("delete_connector", %{"name" => name}, socket) do
    case Provider.delete_config(name) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "Connector '#{name}' deleted")
         |> load_connectors()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to delete connector: #{inspect(reason)}")}
    end
  end

  defp save_connector(socket, type, params) do
    case connector_config(type, params) do
      {:ok, config} ->
        case Provider.put_config(config) do
          :ok ->
            {:noreply,
             socket
             |> put_flash(:info, "Connector '#{config.name}' saved")
             |> close_modal_and_reset_form()
             |> assign(:form_errors, %{})
             |> load_connectors()}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Failed to save connector: #{inspect(reason)}")}
        end

      {:error, errors} ->
        {:noreply,
         socket
         |> assign(:connector_modal_open?, true)
         |> assign(:form_errors, errors)
         |> assign_connector_form(params)}
    end
  end

  defp connector_config(:cloudflare, params) do
    errors =
      %{}
      |> require_field(:name, params["name"], "Connector name is required")
      |> require_field(:api_token, params["api_token"], "API token is required")

    if map_size(errors) == 0 do
      {:ok,
       %{
         name: String.trim(params["name"]),
         type: :cloudflare,
         credentials: %{
           api_token: params["api_token"],
           account_id: String.trim(params["account_id"] || "")
         },
         zones: [],
         enabled: enabled?(params["enabled"])
       }}
    else
      {:error, errors}
    end
  end

  defp connector_config(:route53, params) do
    errors =
      %{}
      |> require_field(:name, params["name"], "Connector name is required")
      |> require_field(
        :access_key_id,
        params["access_key_id"],
        "Access key ID is required"
      )
      |> require_field(
        :secret_access_key,
        params["secret_access_key"],
        "Secret access key is required"
      )

    if map_size(errors) == 0 do
      {:ok,
       %{
         name: String.trim(params["name"]),
         type: :route53,
         credentials: %{
           access_key_id: params["access_key_id"],
           secret_access_key: params["secret_access_key"]
         },
         zones: [],
         enabled: enabled?(params["enabled"])
       }}
    else
      {:error, errors}
    end
  end

  defp require_field(errors, field, value, message) do
    if String.trim(value || "") == "" do
      Map.put(errors, field, message)
    else
      errors
    end
  end

  defp load_connectors(socket) do
    connectors =
      case Provider.list_configs() do
        {:ok, configs} -> configs
        {:error, _reason} -> []
      end

    assign(socket, :connectors, connectors)
  end

  defp close_modal_and_reset_form(socket) do
    assign(
      socket,
      connector_modal_open?: false,
      connector_form: to_form(default_connector_form(), as: :connector)
    )
  end

  defp assign_connector_form(socket, params) do
    assign(
      socket,
      :connector_form,
      to_form(connector_form_data(params), as: :connector)
    )
  end

  defp connector_form_data(params) do
    provider = normalize_provider(params["provider"])

    provider
    |> default_connector_form()
    |> Map.merge(params)
    |> Map.put("provider", provider)
  end

  defp default_connector_form(provider \\ "cloudflare")

  defp default_connector_form("route53") do
    %{
      "provider" => "route53",
      "name" => "aws-prod",
      "access_key_id" => "",
      "secret_access_key" => "",
      "enabled" => "true"
    }
  end

  defp default_connector_form(_provider) do
    %{
      "provider" => "cloudflare",
      "name" => "cf-main",
      "api_token" => "",
      "account_id" => "",
      "enabled" => "true"
    }
  end

  defp enabled?(value) when is_list(value), do: Enum.any?(value, &enabled?/1)
  defp enabled?(true), do: true
  defp enabled?("true"), do: true
  defp enabled?("on"), do: true
  defp enabled?("1"), do: true
  defp enabled?(_value), do: false

  defp selected_provider(form), do: normalize_provider(form[:provider].value)

  defp connector_type(%{"provider" => "route53"}), do: :route53
  defp connector_type(_params), do: :cloudflare

  defp normalize_provider("route53"), do: "route53"
  defp normalize_provider(_provider), do: "cloudflare"

  defp default_name("route53"), do: "aws-prod"
  defp default_name(_provider), do: "cf-main"

  defp provider_label(:cloudflare), do: "Cloudflare DNS"
  defp provider_label(:route53), do: "AWS Route 53"
  defp provider_label(type), do: to_string(type)

  defp masked_credentials(%{type: :cloudflare, credentials: credentials}) do
    token = Map.get(credentials, :api_token) || Map.get(credentials, "api_token")
    "token=#{mask_secret(token)}"
  end

  defp masked_credentials(%{type: :route53, credentials: credentials}) do
    access_key = Map.get(credentials, :access_key_id) || Map.get(credentials, "access_key_id")
    "access_key=#{mask_secret(access_key)}"
  end

  defp masked_credentials(_connector), do: "configured"

  defp mask_secret(nil), do: "not set"

  defp mask_secret(secret) do
    secret = to_string(secret)

    if String.length(secret) <= 4 do
      "****"
    else
      String.slice(secret, 0, 4) <> "..." <> String.slice(secret, -4, 4)
    end
  end
end
