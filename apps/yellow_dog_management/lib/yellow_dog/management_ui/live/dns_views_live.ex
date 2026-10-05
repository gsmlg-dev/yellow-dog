defmodule YellowDog.ManagementUI.DnsViewsLive do
  use YellowDog.ManagementUI, :live_view

  alias YellowDog.Management.{Countries, DnsAcls, Domain}
  alias YellowDog.ManagementUI.{DnsRulesText, Submission}
  alias YellowDog.ManagementUI.Hooks.CurrentPath

  @fields ~w(name priority enabled recursion_enabled ecs_enabled client_rules fallback_forwarders fallback_timeout fallback_retries)
  @boolean_fields ~w(enabled recursion_enabled ecs_enabled)
  @presets ~w(any none localhost localnets)
  @max_integer 9_223_372_036_854_775_807

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "DNS Views",
       worker: nil,
       workers: [],
       service: nil,
       services: [],
       views: [],
       scope_params: %{},
       dirty: false,
       pending_scope: nil,
       editing: nil,
       deleting: nil,
       error: nil,
       field_errors: %{},
       filter: "",
       status_filter: "all",
       country_search: "",
       selected_countries: [],
       country_action: "allow",
       preset: "",
       form: new_form()
     )}
  end

  @impl true
  def handle_params(_params, uri, socket) do
    {:noreply, socket |> load(CurrentPath.route_path_params(socket, uri)) |> reset_form()}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, socket |> load(socket.assigns.scope_params) |> reset_form()}
  end

  def handle_event("cancel", _params, socket),
    do: {:noreply, socket |> clear_editor() |> reset_form()}

  def handle_event("select_worker", %{"scope" => %{"worker_id" => worker_id}}, socket) do
    request_scope(socket, %{"server_id" => worker_id})
  end

  def handle_event("select_service", %{"id" => service_id}, socket) do
    if socket.assigns.worker do
      request_scope(socket, %{
        "server_id" => socket.assigns.worker["id"],
        "service_id" => service_id
      })
    else
      failure(socket, "Select a Worker first")
    end
  end

  def handle_event("confirm_scope", _params, socket) do
    case socket.assigns.pending_scope do
      nil -> {:noreply, socket}
      params -> switch_scope(socket, params)
    end
  end

  def handle_event("cancel_scope", _params, socket),
    do: {:noreply, assign(socket, pending_scope: nil)}

  def handle_event("edit", %{"id" => id}, socket) do
    case scoped_view(socket, id) do
      {:ok, view} ->
        {:noreply,
         socket |> clear_editor() |> assign(editing: view, form: view_form(view)) |> reset_form()}

      {:error, error} ->
        failure(socket, error)
    end
  end

  def handle_event("filter", %{"filter" => filter, "status" => status}, socket)
      when is_binary(filter) and byte_size(filter) <= 512 and status in ~w(all active disabled) do
    {:noreply, assign(socket, filter: filter, status_filter: status)}
  end

  def handle_event("validate", %{"view" => params} = payload, socket) when is_map(params) do
    {:noreply, socket |> retain_fields(params, payload) |> validate_form()}
  end

  def handle_event("toggle_country", %{"code" => code}, socket) when is_binary(code) do
    if Countries.valid?(code) and not default_edit?(socket) do
      selected = socket.assigns.selected_countries
      updated = if code in selected, do: List.delete(selected, code), else: [code | selected]
      {:noreply, assign(socket, selected_countries: Enum.sort(updated), error: nil, dirty: true)}
    else
      failure(socket, "Select a valid country for a non-default View")
    end
  end

  def handle_event("clear_country_search", _params, socket),
    do: {:noreply, assign(socket, country_search: "")}

  def handle_event("save", %{"operation" => operation, "view" => params} = payload, socket)
      when operation in ~w(apply_preset append_countries) and is_map(params) do
    socket = retain_fields(socket, params, payload)

    with :ok <- selected_scope(socket),
         false <- default_edit?(socket),
         text when is_binary(text) <- socket.assigns.form.params["client_rules"],
         {:ok, updated} <- editor_operation(operation, text, socket) do
      {:noreply,
       socket
       |> retain_fields(%{"client_rules" => updated}, payload)
       |> assign(selected_countries: [])
       |> validate_form()}
    else
      {:error, error} -> failure(socket, error)
      _ -> failure(socket, "Default View client rules are read-only")
    end
  end

  def handle_event("save", %{"operation" => _unknown}, socket),
    do: failure(socket, "Invalid editor operation")

  def handle_event("save", %{"view" => params} = payload, socket) when is_map(params) do
    socket = socket |> retain_fields(params, payload) |> validate_form()

    with :ok <- selected_scope(socket),
         {:ok, fields} <- validated_fields(socket) do
      {operation, fields} =
        case socket.assigns.editing do
          nil -> {"create_dns_view", fields}
          view -> {"update_dns_view", Map.merge(fields, identity_fields(view))}
        end

      mutate(socket, operation, fields, "Desired View saved; not executed/exported")
    else
      {:error, {_field, error}} -> failure(socket, error)
      {:error, error} -> failure(socket, error)
    end
  end

  def handle_event("toggle_enabled", %{"id" => id}, socket) do
    with {:ok, view} <- scoped_view(socket, id) do
      fields = Map.put(identity_fields(view), "enabled", not view["enabled"])

      mutate(
        socket,
        "update_dns_view",
        fields,
        "Desired View status saved; not executed/exported"
      )
    else
      {:error, error} -> failure(socket, error)
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    with {:ok, view} <- scoped_view(socket, id),
         false <- view["is_default"] do
      {:noreply, assign(socket, deleting: view, error: nil)}
    else
      true -> failure(socket, "Cannot delete the default View")
      {:error, error} -> failure(socket, error)
    end
  end

  def handle_event("cancel_delete", _params, socket),
    do: {:noreply, assign(socket, deleting: nil, error: nil)}

  def handle_event("confirm_delete", %{"id" => id}, socket) do
    with :ok <- selected_scope(socket),
         %{"id" => ^id, "is_default" => false} = view <- socket.assigns.deleting do
      mutate(
        socket,
        "delete_dns_view",
        identity_fields(view),
        "Desired View deleted; not executed/exported"
      )
    else
      {:error, error} -> failure(socket, error)
      _ -> failure(socket, "Select a non-default View and confirm deletion first")
    end
  end

  def handle_event("export_csv", _params, socket) do
    with :ok <- selected_scope(socket),
         {:ok, views} <-
           Domain.list_dns_views(socket.assigns.worker["id"], socket.assigns.service["id"]) do
      rows =
        views
        |> visible_views(socket.assigns.filter, socket.assigns.status_filter)
        |> Enum.map_join("", fn view ->
          [
            view["name"],
            status(view),
            priority(view),
            flag(view["recursion_enabled"]),
            flag(view["ecs_enabled"])
          ]
          |> Enum.map_join(",", &csv_cell/1)
          |> Kernel.<>("\r\n")
        end)

      {:noreply,
       push_event(socket, "download_csv", %{
         content: "View Name,Status,Priority,Recursion,ECS\r\n" <> rows,
         filename: "dns_views_#{socket.assigns.worker["id"]}_#{socket.assigns.service["id"]}.csv"
       })}
    else
      {:error, error} -> failure(socket, error)
    end
  end

  def handle_event(_event, _params, socket), do: failure(socket, "Invalid View action")

  defp mutate(socket, operation, fields, feedback) do
    params = Map.merge(fields, scope_fields(socket))
    {socket, key} = Submission.prepare(socket, operation, params)

    case Domain.mutate(operation, params, "operator", key) do
      {:ok, _view} ->
        {:noreply,
         socket
         |> load(socket.assigns.scope_params)
         |> clear_flash()
         |> put_flash(:info, feedback)
         |> reset_form()}

      {:error, error} ->
        failure(socket, error)
    end
  end

  defp load(socket, params) do
    socket =
      socket
      |> clear_editor()
      |> assign(
        worker: nil,
        workers: Domain.list_workers(),
        service: nil,
        services: [],
        views: [],
        scope_params: params
      )

    if is_nil(params["server_id"]) do
      socket
    else
      load_worker(socket, params)
    end
  end

  defp load_worker(socket, params) do
    with true <- ServicePaths.valid_server_id?(params["server_id"]),
         {:ok, worker} <- Domain.get_worker(params["server_id"]) do
      services = Enum.filter(worker["services"], &(&1["type"] == "dns"))
      socket = assign(socket, worker: worker, services: services)

      case params do
        %{"service_id" => service_id} ->
          load_service(socket, service_id)

        _ ->
          case services do
            [service] -> load_service(socket, service["id"])
            _ -> socket
          end
      end
    else
      false -> assign(socket, error: "Invalid Worker identifier")
      {:error, error} -> assign(socket, error: message(error))
    end
  end

  defp request_scope(socket, params) do
    same_worker = socket.assigns.worker && socket.assigns.worker["id"] == params["server_id"]

    same_service =
      is_nil(params["service_id"]) ||
        (socket.assigns.service && socket.assigns.service["id"] == params["service_id"])

    cond do
      same_worker && same_service -> {:noreply, socket}
      socket.assigns.dirty -> {:noreply, assign(socket, pending_scope: params)}
      true -> switch_scope(socket, params)
    end
  end

  defp switch_scope(socket, params) do
    with {:ok, worker} <- Domain.get_worker(params["server_id"]),
         true <-
           is_nil(params["service_id"]) ||
             Enum.any?(
               worker["services"],
               &(&1["id"] == params["service_id"] and &1["type"] == "dns")
             ) do
      path =
        if params["service_id"],
          do: ServicePaths.server_path(worker["id"], {:dns_views_service, params["service_id"]}),
          else: ServicePaths.server_path(worker["id"], :dns_views)

      {:noreply, socket |> clear_editor() |> push_patch(to: path)}
    else
      false -> failure(socket, "DNS Service not found for the selected Worker")
      {:error, error} -> failure(socket, error)
    end
  end

  defp load_service(socket, service_id) do
    with {:ok, id} <- uuid(service_id),
         service when not is_nil(service) <-
           Enum.find(socket.assigns.services, &(&1["id"] == id)),
         {:ok, views} <- Domain.list_dns_views(socket.assigns.worker["id"], id) do
      assign(socket, service: service, views: ordered_views(views))
    else
      :error -> assign(socket, error: "Invalid DNS Service UUID")
      nil -> assign(socket, error: "DNS Service not found for the selected Worker")
      {:error, error} -> assign(socket, error: message(error))
    end
  end

  defp selected_scope(%{assigns: %{worker: worker, service: service}})
       when not is_nil(worker) and not is_nil(service),
       do: :ok

  defp selected_scope(_socket), do: {:error, "Select an existing Worker and DNS Service first"}

  defp scope_fields(socket),
    do: %{
      "worker_id" => socket.assigns.worker["id"],
      "service_id" => socket.assigns.service["id"]
    }

  defp identity_fields(view), do: %{"id" => view["id"], "expected_revision" => view["revision"]}

  defp scoped_view(socket, id) do
    with :ok <- selected_scope(socket),
         {:ok, id} <- uuid(id),
         view when not is_nil(view) <- Enum.find(socket.assigns.views, &(&1["id"] == id)) do
      {:ok, view}
    else
      :error -> {:error, "Invalid View UUID"}
      nil -> {:error, "View not found in the selected DNS Service"}
      {:error, error} -> {:error, error}
    end
  end

  defp clear_editor(socket) do
    assign(socket,
      editing: nil,
      dirty: false,
      pending_scope: nil,
      deleting: nil,
      error: nil,
      field_errors: %{},
      form: new_form(),
      country_search: "",
      selected_countries: [],
      country_action: "allow",
      preset: ""
    )
  end

  defp retain_fields(socket, params, payload) do
    fields = Map.merge(socket.assigns.form.params, Map.take(params, @fields))

    fields =
      if socket.assigns.editing,
        do: Map.put(fields, "name", socket.assigns.editing["name"]),
        else: fields

    fields =
      if default_edit?(socket),
        do:
          Map.merge(fields, %{
            "priority" => "",
            "client_rules" => DnsRulesText.format(socket.assigns.editing["client_rules"])
          }),
        else: fields

    assign(socket,
      form: to_form(fields, as: "view"),
      dirty: socket.assigns.dirty || fields != socket.assigns.form.params,
      error: nil,
      country_search: bounded_text(payload["country_search"], socket.assigns.country_search),
      country_action: bounded_text(payload["country_action"], socket.assigns.country_action),
      preset: bounded_text(payload["preset"], socket.assigns.preset)
    )
  end

  defp bounded_text(value, _fallback) when is_binary(value) and byte_size(value) <= 256, do: value
  defp bounded_text(_value, fallback), do: fallback

  defp default_edit?(socket),
    do: socket.assigns.editing != nil and socket.assigns.editing["is_default"]

  defp validate_form(socket) do
    case validated_fields(socket) do
      {:ok, _fields} -> assign(socket, field_errors: %{})
      {:error, {field, error}} -> assign(socket, field_errors: %{field => error})
    end
  end

  defp validated_fields(socket) do
    params = socket.assigns.form.params

    with :ok <- valid_name(params["name"], socket.assigns.editing),
         {:ok, booleans} <- parse_booleans(params),
         {:ok, forwarders} <- parse_forwarders(params["fallback_forwarders"]),
         {:ok, timeout} <- integer(params["fallback_timeout"], 100, 30_000, :fallback_timeout),
         {:ok, retries} <- integer(params["fallback_retries"], 0, 5, :fallback_retries),
         {:ok, policy} <- parse_policy(params, default_edit?(socket)) do
      fields = Map.merge(booleans, policy)

      fields =
        Map.merge(fields, %{
          "fallback_forwarders" => forwarders,
          "fallback_timeout" => timeout,
          "fallback_retries" => retries
        })

      fields =
        if socket.assigns.editing, do: fields, else: Map.put(fields, "name", params["name"])

      {:ok, fields}
    end
  end

  defp valid_name(name, editing) when is_binary(name) do
    if Regex.match?(~r/\A[A-Za-z0-9_-]{1,63}\z/, name) and (name != "default" or editing != nil),
      do: :ok,
      else:
        {:error, {:name, "Name must be a 1–63 character ASCII identifier; default is reserved"}}
  end

  defp valid_name(_name, _editing), do: {:error, {:name, "Invalid View name"}}

  defp parse_booleans(params) do
    Enum.reduce_while(@boolean_fields, {:ok, %{}}, fn field, {:ok, fields} ->
      case params[field] do
        "true" -> {:cont, {:ok, Map.put(fields, field, true)}}
        "false" -> {:cont, {:ok, Map.put(fields, field, false)}}
        _ -> {:halt, {:error, {String.to_existing_atom(field), "Choose Enabled or Disabled"}}}
      end
    end)
  end

  defp parse_policy(_params, true), do: {:ok, %{}}

  defp parse_policy(params, false) do
    with {:ok, priority} <- integer(params["priority"], 0, @max_integer, :priority),
         {:ok, rules} <- DnsRulesText.parse(params["client_rules"]) do
      {:ok, %{"priority" => priority, "client_rules" => rules}}
    else
      {:error, {:rules, error}} -> {:error, {:client_rules, error}}
      {:error, error} -> {:error, error}
    end
  end

  defp integer(value, minimum, maximum, field) when is_binary(value) and byte_size(value) <= 19 do
    with true <- Regex.match?(~r/\A[0-9]+\z/, value),
         {number, ""} <- Integer.parse(value),
         true <- number >= minimum and number <= maximum do
      {:ok, number}
    else
      _ -> {:error, {field, "Must be an integer between #{minimum} and #{maximum}"}}
    end
  end

  defp integer(_value, minimum, maximum, field),
    do: {:error, {field, "Must be an integer between #{minimum} and #{maximum}"}}

  defp parse_forwarders(text) when is_binary(text) and byte_size(text) <= 262_144 do
    text
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, addresses} ->
      case parse_forwarder(line) do
        {:ok, address} ->
          {:cont, {:ok, [address | addresses]}}

        :error ->
          {:halt,
           {:error,
            {:fallback_forwarders,
             "Invalid fallback server: use IPv4[:port], IPv6 or [IPv6]:port"}}}
      end
    end)
    |> case do
      {:ok, addresses} when length(addresses) <= 128 ->
        {:ok, Enum.reverse(addresses)}

      {:ok, _addresses} ->
        {:error, {:fallback_forwarders, "At most 128 fallback endpoints are allowed"}}

      error ->
        error
    end
  end

  defp parse_forwarders(_text),
    do: {:error, {:fallback_forwarders, "Fallback servers text must be at most 256 KiB"}}

  defp parse_forwarder(line) do
    case :inet.parse_strict_address(String.to_charlist(line)) do
      {:ok, address} ->
        {:ok, %{"address" => address |> :inet.ntoa() |> to_string(), "port" => 53}}

      {:error, _reason} ->
        parse_address_port(line)
    end
  end

  defp parse_address_port(line) do
    parts =
      cond do
        String.starts_with?(line, "[") ->
          Regex.run(~r/\A\[([^\]]+)\]:([0-9]+)\z/, line, capture: :all_but_first)

        true ->
          Regex.run(~r/\A([^:]+):([0-9]+)\z/, line, capture: :all_but_first)
      end

    with [address, port] <- parts,
         {:ok, tuple} <- :inet.parse_strict_address(String.to_charlist(address)),
         true <- tuple_size(tuple) == if(String.starts_with?(line, "["), do: 8, else: 4),
         {:ok, port} <- integer(port, 1, 65_535, :fallback_forwarders) do
      {:ok, %{"address" => tuple |> :inet.ntoa() |> to_string(), "port" => port}}
    else
      _ -> :error
    end
  end

  defp editor_operation("apply_preset", text, socket) do
    if String.trim(text) == "" do
      with {:ok, rules} <- DnsAcls.preset_rules(socket.assigns.preset),
           do: {:ok, DnsRulesText.format(rules)}
    else
      {:error, "Presets apply only to an empty rules editor; existing rules were retained"}
    end
  end

  defp editor_operation("append_countries", text, socket) do
    if socket.assigns.country_action in ~w(allow deny) and socket.assigns.selected_countries != [] do
      separator = if text == "" or String.ends_with?(text, "\n"), do: "", else: "\n"

      {:ok,
       text <>
         separator <>
         socket.assigns.country_action <>
         " countries " <> Enum.join(socket.assigns.selected_countries, ", ")}
    else
      {:error, "Select countries and an allow/deny action before appending"}
    end
  end

  defp new_form do
    to_form(
      %{
        "name" => "",
        "priority" => "100",
        "enabled" => "true",
        "recursion_enabled" => "true",
        "ecs_enabled" => "false",
        "client_rules" => "allow any",
        "fallback_forwarders" => "",
        "fallback_timeout" => "2000",
        "fallback_retries" => "1"
      },
      as: "view"
    )
  end

  defp view_form(view) do
    fields = Map.take(view, @fields)

    fields =
      Enum.reduce(@boolean_fields, fields, fn field, fields ->
        Map.update!(fields, field, &to_string/1)
      end)

    fields =
      Map.merge(fields, %{
        "priority" => if(view["is_default"], do: "", else: to_string(view["priority"])),
        "client_rules" => DnsRulesText.format(view["client_rules"]),
        "fallback_forwarders" => format_forwarders(view["fallback_forwarders"]),
        "fallback_timeout" => to_string(view["fallback_timeout"]),
        "fallback_retries" => to_string(view["fallback_retries"])
      })

    to_form(fields, as: "view")
  end

  defp format_forwarders(forwarders) do
    Enum.map_join(forwarders, "\n", fn %{"address" => address, "port" => port} ->
      cond do
        port == 53 -> address
        String.contains?(address, ":") -> "[#{address}]:#{port}"
        true -> "#{address}:#{port}"
      end
    end)
  end

  defp ordered_views(views),
    do: Enum.sort_by(views, &{&1["is_default"], &1["priority"], &1["name"], &1["id"]})

  defp visible_views(views, filter, status_filter) do
    views
    |> ordered_views()
    |> Enum.filter(fn view ->
      String.contains?(String.downcase(view["name"]), String.downcase(filter)) and
        (status_filter == "all" or view["enabled"] == (status_filter == "active"))
    end)
  end

  defp priority(%{"is_default" => true}), do: "infinity"
  defp priority(view), do: to_string(view["priority"])
  defp status(view), do: if(view["enabled"], do: "Active", else: "Disabled")
  defp flag(value), do: if(value, do: "Enabled", else: "Disabled")
  defp uuid(value) when is_binary(value) and byte_size(value) == 36, do: Ecto.UUID.cast(value)
  defp uuid(_value), do: :error

  defp field_value(form, field) do
    case form[field].value do
      value when is_binary(value) -> value
      _ -> ""
    end
  end

  defp csv_cell(value) do
    safe =
      if String.starts_with?(String.trim_leading(value), ["=", "+", "-", "@"]),
        do: "'" <> value,
        else: value

    if String.contains?(safe, [",", "\"", "\n", "\r"]),
      do: "\"" <> String.replace(safe, "\"", "\"\"") <> "\"",
      else: safe
  end

  defp failure(socket, error),
    do: {:noreply, socket |> clear_flash(:info) |> assign(error: message(error))}

  defp message(%{message: message}), do: message
  defp message(%{"message" => message}), do: message
  defp message(message) when is_binary(message), do: message
  defp message(_error), do: "View operation failed"

  defp reset_form(socket) do
    values = Map.new(@fields, &{"view[#{&1}]", socket.assigns.form.params[&1]})
    push_event(socket, "set_form_values", %{id: "dns-view-form", values: values})
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        visible: visible_views(assigns.views, assigns.filter, assigns.status_filter),
        countries: Countries.search(assigns.country_search),
        presets: @presets,
        default_edit: assigns.editing != nil and assigns.editing["is_default"],
        boolean_fields: @boolean_fields
      )

    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <.card title="DNS Views">
        <p class="management-help">
          Desired configuration only. Views do not execute DNS, enforce client rules or change Worker exports.
        </p>
        <p :if={@error} id="dns-view-error" class="text-error" role="alert">{@error}</p>
        <form id="dns-view-worker-selector" phx-change="select_worker">
          <label class="management-field">
            <span>Worker</span>
            <select class="select select-bordered" name="scope[worker_id]">
              <option value="" selected={is_nil(@worker)}>Select a logical Worker</option>
              <option
                :for={worker <- @workers}
                value={worker["id"]}
                selected={@worker && @worker["id"] == worker["id"]}
              >
                {worker["name"]} ({worker["id"]})
              </option>
            </select>
          </label>
        </form>
        <p :if={@workers == []}>Register a logical Worker before configuring a DNS View.</p>
        <section :if={@pending_scope} id="dns-view-unsaved-scope" role="alert">
          <p>Discard unsaved View changes to change Worker or DNS Service?</p>
          <button class="btn btn-error" phx-click="confirm_scope">Discard changes and switch scope</button>
          <button class="btn btn-secondary" phx-click="cancel_scope">Keep editing</button>
        </section>
        <p :if={@worker}>Worker: {@worker["name"]} ({@worker["id"]})</p>
        <p :if={@service}>DNS Service: {@service["instance_id"]} ({@service["id"]})</p>
        <div :if={@worker} id="dns-view-service-selector" class="management-actions">
          <p :if={length(@services) > 1}>Select a DNS Service explicitly.</p>
          <p :if={@services == []}>
            No DNS Services configured.
            <.link navigate={ServicePaths.server_path(@worker["id"], :dashboard)}>Configure a DNS Service</.link>
          </p>
          <button
            :for={service <- @services}
            phx-click="select_service"
            phx-value-id={service["id"]}
            class="btn btn-secondary"
            data-service-id={service["id"]}
            aria-current={if @service && @service["id"] == service["id"], do: "page", else: nil}
          >{service["instance_id"]} ({service["id"]})</button>
        </div>
        <div :if={@service} class="management-actions">
          <button id="dns-view-refresh" type="button" class="btn btn-ghost" phx-click="refresh">Refresh</button>
          <button
            id="dns-view-export"
            type="button"
            class="btn btn-ghost"
            phx-click="export_csv"
            phx-hook="CsvDownload"
          >Export Filtered Views CSV</button>
        </div>
      </.card>
      <.form
        :if={@service}
        for={%{}}
        id="dns-view-filter-form"
        phx-change="filter"
        phx-submit="filter"
      >
        <div class="management-actions">
          <label class="management-field"><span>Filter by View Name</span><input
            id="dns-view-filter"
            class="input input-bordered"
            name="filter"
            value={@filter}
            maxlength="512"
            phx-debounce="300"
          /></label>
          <label class="management-field"><span>Desired Status</span><select
            id="dns-view-status-filter"
            class="select select-bordered"
            name="status"
          >
            <option value="all" selected={@status_filter == "all"}>All Status</option>
            <option value="active" selected={@status_filter == "active"}>
              Active (desired enabled)
            </option>
            <option value="disabled" selected={@status_filter == "disabled"}>
              Disabled (desired)
            </option>
          </select></label>
        </div>
      </.form>
      <.card :if={@service} title="Desired Views">
        <p id="dns-view-count">Showing {length(@visible)} of {length(@views)} view(s)</p>
        <p :if={@visible == []}>No matching DNS Views. Create a View using the form below.</p>
        <div class="management-records">
          <table id="dns-views-table" class="table table-striped">
            <thead>
              <tr>
                <th>Name</th><th>Desired Status</th><th>Priority</th><th>Recursion</th><th>ECS</th><th>
                  Client Rules
                </th><th>Actions</th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={view <- @visible}
                id={"dns-view-#{view["id"]}"}
                data-view-name={view["name"]}
                data-view-revision={view["revision"]}
                data-view-enabled={to_string(view["enabled"])}
                data-view-default={to_string(view["is_default"])}
                data-view-rules={Jason.encode!(view["client_rules"])}
                data-view-priority={priority(view)}
              >
                <td>
                  {view["name"]}
                  <.badge :if={view["is_default"]} color="ghost">default</.badge>
                </td>
                <td>
                  <button
                    type="button"
                    class="btn btn-ghost btn-sm"
                    phx-click="toggle_enabled"
                    phx-disable-with="Saving…"
                    phx-value-id={view["id"]}
                  >{status(view)}</button>
                </td>
                <td>{if view["is_default"], do: "∞ (last / catch-all)", else: priority(view)}</td>
                <td>{flag(view["recursion_enabled"])}</td><td>{flag(view["ecs_enabled"])}</td>
                <td>
                  <pre>{DnsRulesText.format(view["client_rules"])}</pre><p :if={
                    view["client_rules"] == []
                  }>
                    Zero rules; not an any rule.
                  </p>
                </td>
                <td>
                  <div class="management-actions">
                    <button
                      type="button"
                      class="btn btn-secondary btn-sm"
                      phx-click="edit"
                      phx-value-id={view["id"]}
                    >Edit View / Client ACL</button>
                    <button
                      :if={!view["is_default"]}
                      type="button"
                      class="btn btn-error btn-sm"
                      phx-click="delete"
                      phx-value-id={view["id"]}
                    >Delete</button>
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </.card>
      <.card :if={@service} title={if @editing, do: "Edit Desired View", else: "Create Desired View"}>
        <p :if={@editing}>
          Editing {@editing["id"]}, revision {@editing["revision"]}. Name is immutable.
        </p>
        <.form
          for={@form}
          id="dns-view-form"
          phx-submit="save"
          phx-change="validate"
          phx-hook="ResetForm"
        >
          <div class="management-actions">
            <button
              id="dns-view-save"
              phx-disable-with="Saving…"
              class="btn btn-primary"
              type="submit"
              disabled={@field_errors != %{}}
            >{if @editing, do: "Save Desired View", else: "Create Desired View"}</button>
            <button id="dns-view-cancel" type="button" class="btn btn-ghost" phx-click="cancel">Cancel / Reset</button>
          </div>
          <p
            :for={{field, error} <- @field_errors}
            id={"dns-view-#{field}-error"}
            class="text-error"
            role="alert"
          >
            {error}
          </p>
          <label class="management-field"><span>View Name</span><input
            class="input input-bordered"
            name="view[name]"
            value={field_value(@form, :name)}
            maxlength="63"
            required
            disabled={@editing != nil}
          /></label>
          <label :if={!@default_edit} class="management-field"><span>Priority (lower is matched first)</span><input
            class="input input-bordered"
            name="view[priority]"
            value={field_value(@form, :priority)}
            type="number"
            min="0"
            max="9223372036854775807"
            required
          /></label>
          <p :if={@default_edit} class="management-help">
            Default View is last / catch-all. Priority and client rules are read-only; default cannot be deleted.
          </p>
          <label :for={field <- @boolean_fields} class="management-field"><span>{case field do
            "enabled" -> "Desired Enabled"
            "recursion_enabled" -> "Enable Recursion (desired)"
            "ecs_enabled" -> "Enable ECS (desired)"
          end}</span><select class="select select-bordered" name={"view[#{field}]"}>
            <option value="true" selected={@form.params[field] == "true"}>Enabled</option>
            <option value="false" selected={@form.params[field] == "false"}>Disabled</option>
          </select></label>
          <label class="management-field"><span>Client ACL: Ordered Rules (one per line)</span><textarea
            id="dns-view-rules"
            class="textarea textarea-bordered"
            name={if !@default_edit, do: "view[client_rules]", else: nil}
            rows="8"
            maxlength="262144"
            readonly={@default_edit}
          >{field_value(@form, :client_rules)}</textarea></label>
          <p class="management-help">
            allow|deny any; allow|deny networks IP_OR_CIDR[, ...]; allow|deny countries ISO[, ...]. Blank text means zero rules; bare networks means an empty set, never any.
          </p>
          <div :if={!@default_edit}>
            <label class="management-field"><span>Built-in Preset</span><select
              id="dns-view-preset"
              name="preset"
              class="select select-bordered"
            >
              <option value="">Select a preset</option><option
                :for={preset <- @presets}
                value={preset}
                selected={@preset == preset}
              >
                {preset}
              </option>
            </select></label>
            <button
              id="dns-view-apply-preset"
              type="submit"
              name="operation"
              value="apply_preset"
              formnovalidate
              class="btn btn-secondary"
            >Apply Preset to Empty Editor</button>
            <details id="dns-view-country-picker" open>
              <summary>Append a Countries Rule</summary>
              <label class="management-field"><span>Search Countries</span><input
                id="dns-view-country-search"
                class="input input-bordered"
                name="country_search"
                value={@country_search}
                maxlength="256"
                phx-debounce="300"
              /></label>
              <button type="button" class="btn btn-ghost" phx-click="clear_country_search">Clear Country Search</button>
              <p>{length(@selected_countries)} countries selected; {length(@countries)} shown.</p>
              <div class="management-actions">
                <button
                  :for={code <- @selected_countries}
                  type="button"
                  class="badge badge-secondary"
                  phx-click="toggle_country"
                  phx-value-code={code}
                  data-selected-country-code={code}
                >{code} ×</button>
              </div>
              <div class="management-actions">
                <label :for={country <- @countries}><input
                  id={"dns-view-country-#{country.code}"}
                  type="checkbox"
                  class="checkbox"
                  checked={country.code in @selected_countries}
                  phx-click="toggle_country"
                  phx-value-code={country.code}
                  data-country-code={country.code}
                />{country.code} — {country.name}</label>
              </div>
              <label class="management-field"><span>Countries Rule Action</span><select
                id="dns-view-country-action"
                name="country_action"
                class="select select-bordered"
              ><option value="allow" selected={@country_action == "allow"}>Allow</option><option
                value="deny"
                selected={@country_action == "deny"}
              >
                Deny
              </option></select></label>
              <button
                id="dns-view-add-countries"
                type="submit"
                name="operation"
                value="append_countries"
                formnovalidate
                class="btn btn-secondary"
              >Append Selected Countries</button>
            </details>
          </div>
          <label class="management-field"><span>Fallback DNS Servers (one per line)</span><textarea
            id="dns-view-forwarders"
            class="textarea textarea-bordered"
            name="view[fallback_forwarders]"
            rows="4"
            maxlength="262144"
          >{field_value(@form, :fallback_forwarders)}</textarea></label>
          <p class="management-help">
            IPv4[:port], plain IPv6 or [IPv6]:port. Default port 53. Empty list is allowed; stored policy does not perform forwarding.
          </p>
          <label class="management-field"><span>Timeout (ms)</span><input
            class="input input-bordered"
            name="view[fallback_timeout]"
            type="number"
            min="100"
            max="30000"
            value={field_value(@form, :fallback_timeout)}
            required
          /></label>
          <label class="management-field"><span>Retries</span><input
            class="input input-bordered"
            name="view[fallback_retries]"
            type="number"
            min="0"
            max="5"
            value={field_value(@form, :fallback_retries)}
            required
          /></label>
        </.form>
      </.card>
      <.modal
        :if={@deleting}
        id="dns-view-delete-modal"
        title="Confirm Desired View Deletion"
        show
        on_cancel={JS.push("cancel_delete")}
      >
        <p>
          Delete {@deleting["name"]} at revision {@deleting["revision"]}? Only desired View data changes; no Worker execution or export changes.
        </p>
        <div class="management-actions">
          <button
            id="dns-view-confirm-delete"
            type="button"
            class="btn btn-error"
            phx-click="confirm_delete"
            phx-disable-with="Deleting…"
            phx-value-id={@deleting["id"]}
          >Confirm Delete</button><button
            id="dns-view-cancel-delete"
            type="button"
            class="btn btn-ghost"
            phx-click="cancel_delete"
          >Cancel</button>
        </div>
      </.modal>
    </Layouts.app>
    """
  end
end
