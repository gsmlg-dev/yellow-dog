defmodule YellowDog.Console.Components.RecordForm do
  @moduledoc """
  LiveComponent for DNS record editing with real-time validation.

  This component provides:
  - Type-specific form fields (different fields for MX, SRV, CAA, etc.)
  - Real-time validation feedback using `phx-change`
  - Conflict detection warnings (e.g., CNAME at existing name)
  - Integration with DNS.Zone.Validator.Record for RFC-compliant validation

  ## Usage

      <.live_component
        module={YellowDog.Console.Components.RecordForm}
        id="record-form"
        zone_name="example.com"
        zone_pid={@zone_pid}
        record={@editing_record}
        on_save={fn record -> send(self(), {:record_saved, record}) end}
        on_cancel={fn -> send(self(), :record_cancelled) end}
      />

  ## Assigns

  - `:zone_name` - The zone name for relative name resolution
  - `:zone_pid` - PID of the Auth zone process (optional, for conflict detection)
  - `:record` - Existing record map for editing, or nil for new record
  - `:on_save` - Callback function when form is submitted successfully
  - `:on_cancel` - Callback function when form is cancelled

  """
  use YellowDog.Console, :live_component

  alias DNS.Zone.Validator.Record, as: RecordValidator

  @supported_types ~w(a aaaa cname mx ns txt srv ptr caa)

  # ============================================================================
  # Lifecycle
  # ============================================================================

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:errors, %{})
     |> assign(:warnings, [])
     |> assign(:validated, false)}
  end

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    # Initialize form data from record or defaults
    form_data =
      if assigns[:record] do
        record_to_form(assigns.record)
      else
        default_form_data()
      end

    {:ok,
     socket
     |> assign(:form_data, form_data)
     |> assign(:form, to_form(form_data))
     |> assign(:supported_types, @supported_types)}
  end

  # ============================================================================
  # Event Handlers
  # ============================================================================

  @impl true
  def handle_event("validate", %{"record" => params}, socket) do
    # Merge new params with existing form data
    form_data = Map.merge(socket.assigns.form_data, params)
    type = safe_record_type(form_data["type"])

    # Build validation params
    validation_params = build_validation_params(type, form_data, socket.assigns.zone_name)

    # Run validation
    {errors, warnings} = validate_record(type, validation_params, socket)

    {:noreply,
     socket
     |> assign(:form_data, form_data)
     |> assign(:form, to_form(form_data))
     |> assign(:errors, errors)
     |> assign(:warnings, warnings)
     |> assign(:validated, true)}
  end

  @impl true
  def handle_event("save", %{"record" => params}, socket) do
    form_data = Map.merge(socket.assigns.form_data, params)
    type = safe_record_type(form_data["type"])

    validation_params = build_validation_params(type, form_data, socket.assigns.zone_name)

    case RecordValidator.validate(type, validation_params) do
      {:ok, validated_record} ->
        if socket.assigns[:on_save] do
          socket.assigns.on_save.(validated_record)
        end

        {:noreply, socket}

      {:error, errors} ->
        {:noreply, assign(socket, :errors, errors_to_map(errors))}
    end
  end

  @impl true
  def handle_event("cancel", _params, socket) do
    if socket.assigns[:on_cancel] do
      socket.assigns.on_cancel.()
    end

    {:noreply, socket}
  end

  @impl true
  def handle_event("change_type", %{"record" => %{"type" => new_type}}, socket) do
    # Reset type-specific fields when type changes
    form_data =
      socket.assigns.form_data
      |> Map.put("type", new_type)
      |> reset_type_specific_fields(new_type)

    {:noreply,
     socket
     |> assign(:form_data, form_data)
     |> assign(:form, to_form(form_data))
     |> assign(:errors, %{})
     |> assign(:warnings, [])}
  end

  # ============================================================================
  # Render
  # ============================================================================

  @impl true
  def render(assigns) do
    ~H"""
    <div class="card bg-base-200">
      <div class="card-body">
        <h3 class="card-title text-lg">
          {if @record, do: "Edit Record", else: "New Record"}
        </h3>

        <.form
          for={@form}
          phx-target={@myself}
          phx-change="validate"
          phx-debounce="blur"
          phx-submit="save"
          class="space-y-4"
        >
          <%!-- Record Type Selection --%>
          <div class="form-control">
            <label class="label">
              <span class="label-text font-medium">Type</span>
            </label>
            <select
              name="record[type]"
              aria-label="Record type"
              class={["select select-bordered w-full", @errors[:type] && "select-error"]}
              phx-change="change_type"
              phx-target={@myself}
            >
              <%= for type <- @supported_types do %>
                <option value={type} selected={@form_data["type"] == type}>
                  {String.upcase(type)}
                </option>
              <% end %>
            </select>
            <.field_error errors={@errors} field={:type} />
          </div>

          <%!-- Record Name --%>
          <div class="form-control">
            <label class="label">
              <span class="label-text font-medium">Name</span>
              <span class="label-text-alt text-base-content/60">
                @ for zone apex, or subdomain
              </span>
            </label>
            <input
              type="text"
              name="record[name]"
              value={@form_data["name"]}
              placeholder={"@ or subdomain.#{@zone_name}"}
              maxlength="253"
              class={["input input-bordered w-full", @errors[:name] && "input-error"]}
            />
            <.field_error errors={@errors} field={:name} />
          </div>

          <%!-- TTL --%>
          <div class="form-control">
            <label class="label">
              <span class="label-text font-medium">TTL (seconds)</span>
            </label>
            <input
              type="number"
              name="record[ttl]"
              value={@form_data["ttl"]}
              placeholder="3600"
              min="0"
              class={["input input-bordered w-full", @errors[:ttl] && "input-error"]}
            />
            <.field_error errors={@errors} field={:ttl} />
          </div>

          <%!-- Type-specific fields --%>
          <.type_specific_fields
            type={@form_data["type"]}
            form_data={@form_data}
            errors={@errors}
          />

          <%!-- Warnings --%>
          <%= if @warnings != [] do %>
            <div class="alert alert-warning">
              <svg
                xmlns="http://www.w3.org/2000/svg"
                class="h-6 w-6 shrink-0 stroke-current"
                fill="none"
                viewBox="0 0 24 24"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z"
                />
              </svg>
              <div>
                <%= for warning <- @warnings do %>
                  <p>{warning}</p>
                <% end %>
              </div>
            </div>
          <% end %>

          <%!-- Form Actions --%>
          <div class="card-actions justify-end pt-4">
            <button type="button" class="btn btn-ghost" phx-click="cancel" phx-target={@myself}>
              Cancel
            </button>
            <button
              type="submit"
              phx-disable-with="Saving..."
              class="btn btn-primary"
              disabled={@validated and map_size(@errors) > 0}
            >
              {if @record, do: "Update Record", else: "Add Record"}
            </button>
          </div>
        </.form>
      </div>
    </div>
    """
  end

  # ============================================================================
  # Type-Specific Field Components
  # ============================================================================

  defp type_specific_fields(%{type: "a"} = assigns) do
    ~H"""
    <div class="form-control">
      <label class="label">
        <span class="label-text font-medium">IPv4 Address</span>
      </label>
      <input
        type="text"
        name="record[rdata]"
        value={@form_data["rdata"]}
        placeholder="192.0.2.1"
        class={["input input-bordered w-full font-mono", @errors[:rdata] && "input-error"]}
      />
      <.field_error errors={@errors} field={:rdata} />
    </div>
    """
  end

  defp type_specific_fields(%{type: "aaaa"} = assigns) do
    ~H"""
    <div class="form-control">
      <label class="label">
        <span class="label-text font-medium">IPv6 Address</span>
      </label>
      <input
        type="text"
        name="record[rdata]"
        value={@form_data["rdata"]}
        placeholder="2001:db8::1"
        class={["input input-bordered w-full font-mono", @errors[:rdata] && "input-error"]}
      />
      <.field_error errors={@errors} field={:rdata} />
    </div>
    """
  end

  defp type_specific_fields(%{type: "cname"} = assigns) do
    ~H"""
    <div class="form-control">
      <label class="label">
        <span class="label-text font-medium">Target (Canonical Name)</span>
      </label>
      <input
        type="text"
        name="record[rdata]"
        value={@form_data["rdata"]}
        placeholder="target.example.com."
        class={["input input-bordered w-full", @errors[:rdata] && "input-error"]}
      />
      <.field_error errors={@errors} field={:rdata} />
    </div>
    """
  end

  defp type_specific_fields(%{type: "mx"} = assigns) do
    ~H"""
    <div class="grid grid-cols-1 md:grid-cols-4 gap-4">
      <div class="form-control md:col-span-1">
        <label class="label">
          <span class="label-text font-medium">Priority</span>
        </label>
        <input
          type="number"
          name="record[priority]"
          value={@form_data["priority"]}
          placeholder="10"
          min="0"
          max="65535"
          class={["input input-bordered w-full", @errors[:priority] && "input-error"]}
        />
        <.field_error errors={@errors} field={:priority} />
      </div>
      <div class="form-control md:col-span-3">
        <label class="label">
          <span class="label-text font-medium">Mail Server</span>
        </label>
        <input
          type="text"
          name="record[target]"
          value={@form_data["target"]}
          placeholder="mail.example.com."
          class={["input input-bordered w-full", @errors[:target] && "input-error"]}
        />
        <.field_error errors={@errors} field={:target} />
      </div>
    </div>
    """
  end

  defp type_specific_fields(%{type: "srv"} = assigns) do
    ~H"""
    <div class="grid grid-cols-2 md:grid-cols-4 gap-4">
      <div class="form-control">
        <label class="label">
          <span class="label-text font-medium">Priority</span>
        </label>
        <input
          type="number"
          name="record[priority]"
          value={@form_data["priority"]}
          placeholder="0"
          min="0"
          max="65535"
          class={["input input-bordered w-full", @errors[:priority] && "input-error"]}
        />
        <.field_error errors={@errors} field={:priority} />
      </div>
      <div class="form-control">
        <label class="label">
          <span class="label-text font-medium">Weight</span>
        </label>
        <input
          type="number"
          name="record[weight]"
          value={@form_data["weight"]}
          placeholder="5"
          min="0"
          max="65535"
          class={["input input-bordered w-full", @errors[:weight] && "input-error"]}
        />
        <.field_error errors={@errors} field={:weight} />
      </div>
      <div class="form-control">
        <label class="label">
          <span class="label-text font-medium">Port</span>
        </label>
        <input
          type="number"
          name="record[port]"
          value={@form_data["port"]}
          placeholder="443"
          min="0"
          max="65535"
          class={["input input-bordered w-full", @errors[:port] && "input-error"]}
        />
        <.field_error errors={@errors} field={:port} />
      </div>
      <div class="form-control md:col-span-4">
        <label class="label">
          <span class="label-text font-medium">Target</span>
        </label>
        <input
          type="text"
          name="record[target]"
          value={@form_data["target"]}
          placeholder="server.example.com."
          class={["input input-bordered w-full", @errors[:target] && "input-error"]}
        />
        <.field_error errors={@errors} field={:target} />
      </div>
    </div>
    """
  end

  defp type_specific_fields(%{type: "txt"} = assigns) do
    ~H"""
    <div class="form-control">
      <label class="label">
        <span class="label-text font-medium">Text Data</span>
        <span class="label-text-alt text-base-content/60">
          Max 255 bytes per string
        </span>
      </label>
      <textarea
        name="record[rdata]"
        placeholder={~s(v=spf1 include:_spf.google.com ~all)}
        rows="3"
        class={["textarea textarea-bordered w-full font-mono", @errors[:rdata] && "textarea-error"]}
      ><%= @form_data["rdata"] %></textarea>
      <.field_error errors={@errors} field={:rdata} />
    </div>
    """
  end

  defp type_specific_fields(%{type: "ns"} = assigns) do
    ~H"""
    <div class="form-control">
      <label class="label">
        <span class="label-text font-medium">Nameserver</span>
      </label>
      <input
        type="text"
        name="record[rdata]"
        value={@form_data["rdata"]}
        placeholder="ns1.example.com."
        class={["input input-bordered w-full", @errors[:rdata] && "input-error"]}
      />
      <.field_error errors={@errors} field={:rdata} />
    </div>
    """
  end

  defp type_specific_fields(%{type: "ptr"} = assigns) do
    ~H"""
    <div class="form-control">
      <label class="label">
        <span class="label-text font-medium">Target Domain</span>
      </label>
      <input
        type="text"
        name="record[rdata]"
        value={@form_data["rdata"]}
        placeholder="host.example.com."
        class={["input input-bordered w-full", @errors[:rdata] && "input-error"]}
      />
      <.field_error errors={@errors} field={:rdata} />
    </div>
    """
  end

  defp type_specific_fields(%{type: "caa"} = assigns) do
    ~H"""
    <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
      <div class="form-control">
        <label class="label">
          <span class="label-text font-medium">Flags</span>
        </label>
        <input
          type="number"
          name="record[flags]"
          value={@form_data["flags"] || "0"}
          placeholder="0"
          min="0"
          max="255"
          class={["input input-bordered w-full", @errors[:flags] && "input-error"]}
        />
        <.field_error errors={@errors} field={:flags} />
      </div>
      <div class="form-control">
        <label class="label">
          <span class="label-text font-medium">Tag</span>
        </label>
        <select
          name="record[tag]"
          aria-label="CAA tag"
          class={["select select-bordered w-full", @errors[:tag] && "select-error"]}
        >
          <option value="issue" selected={@form_data["tag"] == "issue"}>issue</option>
          <option value="issuewild" selected={@form_data["tag"] == "issuewild"}>issuewild</option>
          <option value="iodef" selected={@form_data["tag"] == "iodef"}>iodef</option>
        </select>
        <.field_error errors={@errors} field={:tag} />
      </div>
      <div class="form-control md:col-span-3">
        <label class="label">
          <span class="label-text font-medium">Value</span>
        </label>
        <input
          type="text"
          name="record[value]"
          value={@form_data["value"]}
          placeholder="letsencrypt.org"
          class={["input input-bordered w-full", @errors[:value] && "input-error"]}
        />
        <.field_error errors={@errors} field={:value} />
      </div>
    </div>
    """
  end

  # Fallback for unknown types
  defp type_specific_fields(assigns) do
    ~H"""
    <div class="form-control">
      <label class="label">
        <span class="label-text font-medium">Record Data</span>
      </label>
      <input
        type="text"
        name="record[rdata]"
        value={@form_data["rdata"]}
        placeholder="Record data"
        class={["input input-bordered w-full", @errors[:rdata] && "input-error"]}
      />
      <.field_error errors={@errors} field={:rdata} />
    </div>
    """
  end

  # ============================================================================
  # Helper Components
  # ============================================================================

  defp field_error(assigns) do
    error = assigns.errors[assigns.field]

    assigns = assign(assigns, :error, error)

    ~H"""
    <%= if @error do %>
      <label class="label">
        <span class="label-text-alt text-error">{@error}</span>
      </label>
    <% end %>
    """
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp default_form_data do
    %{
      "name" => "",
      "type" => "a",
      "ttl" => "3600",
      "rdata" => "",
      "priority" => "",
      "weight" => "",
      "port" => "",
      "target" => "",
      "flags" => "0",
      "tag" => "issue",
      "value" => ""
    }
  end

  defp record_to_form(record) do
    type = to_string(record[:type] || record["type"] || "a")

    base = %{
      "name" => record[:name] || record["name"] || "",
      "type" => type,
      "ttl" => to_string(record[:ttl] || record["ttl"] || "3600")
    }

    # Add type-specific fields
    case type do
      "mx" ->
        {priority, target} = extract_mx_rdata(record[:rdata] || record["rdata"])

        Map.merge(base, %{
          "priority" => to_string(priority),
          "target" => target
        })

      "srv" ->
        {priority, weight, port, target} = extract_srv_rdata(record[:rdata] || record["rdata"])

        Map.merge(base, %{
          "priority" => to_string(priority),
          "weight" => to_string(weight),
          "port" => to_string(port),
          "target" => target
        })

      "caa" ->
        {flags, tag, value} = extract_caa_rdata(record[:rdata] || record["rdata"])

        Map.merge(base, %{
          "flags" => to_string(flags),
          "tag" => tag,
          "value" => value
        })

      _ ->
        Map.put(base, "rdata", format_rdata(record[:rdata] || record["rdata"]))
    end
  end

  defp extract_mx_rdata({priority, target}), do: {priority, to_string(target)}
  defp extract_mx_rdata(%{preference: p, exchange: e}), do: {p, to_string(e)}
  defp extract_mx_rdata(_), do: {10, ""}

  defp extract_srv_rdata({priority, weight, port, target}),
    do: {priority, weight, port, to_string(target)}

  defp extract_srv_rdata(%{priority: p, weight: w, port: port, target: t}),
    do: {p, w, port, to_string(t)}

  defp extract_srv_rdata(_), do: {0, 0, 0, ""}

  defp extract_caa_rdata({flags, tag, value}), do: {flags, tag, value}
  defp extract_caa_rdata(%{flags: f, tag: t, value: v}), do: {f, t, v}
  defp extract_caa_rdata(_), do: {0, "issue", ""}

  defp format_rdata(nil), do: ""
  defp format_rdata(rdata) when is_binary(rdata), do: rdata

  defp format_rdata(rdata) when is_tuple(rdata) do
    case tuple_size(rdata) do
      4 -> :inet.ntoa(rdata) |> to_string()
      8 -> :inet.ntoa(rdata) |> to_string()
      _ -> inspect(rdata)
    end
  end

  defp format_rdata(rdata) when is_list(rdata), do: Enum.join(rdata, " ")
  defp format_rdata(rdata), do: to_string(rdata)

  defp reset_type_specific_fields(form_data, _type) do
    form_data
    |> Map.put("rdata", "")
    |> Map.put("priority", "")
    |> Map.put("weight", "")
    |> Map.put("port", "")
    |> Map.put("target", "")
    |> Map.put("flags", "0")
    |> Map.put("tag", "issue")
    |> Map.put("value", "")
  end

  defp build_validation_params(type, form_data, zone_name) do
    name = normalize_name(form_data["name"], zone_name)
    ttl = form_data["ttl"]

    base = %{name: name, ttl: ttl}

    case type do
      :mx ->
        Map.merge(base, %{
          priority: form_data["priority"],
          target: form_data["target"]
        })

      :srv ->
        Map.merge(base, %{
          priority: form_data["priority"],
          weight: form_data["weight"],
          port: form_data["port"],
          target: form_data["target"]
        })

      :caa ->
        Map.merge(base, %{
          flags: form_data["flags"],
          tag: form_data["tag"],
          value: form_data["value"]
        })

      _ ->
        Map.put(base, :rdata, form_data["rdata"])
    end
  end

  defp normalize_name(name, zone_name) do
    trimmed = String.trim(to_string(name || ""))

    cond do
      trimmed in ["", "@"] -> ""
      String.ends_with?(trimmed, ".") -> String.trim_trailing(trimmed, ".")
      String.ends_with?(trimmed, zone_name) -> trimmed
      String.contains?(trimmed, ".") -> trimmed
      true -> "#{trimmed}.#{zone_name}"
    end
  end

  defp validate_record(type, params, socket) do
    case RecordValidator.validate(type, params) do
      {:ok, validated} ->
        # Check for conflicts if zone_pid is available
        warnings = check_conflicts(validated, socket)
        {%{}, warnings}

      {:error, errors} ->
        {errors_to_map(errors), []}
    end
  end

  defp errors_to_map(errors) when is_list(errors) do
    errors
    |> Enum.map(fn
      %{field: field, message: message} -> {field, message}
      error -> {:general, inspect(error)}
    end)
    |> Map.new()
  end

  defp errors_to_map(_), do: %{}

  defp check_conflicts(validated, socket) do
    zone_pid = socket.assigns[:zone_pid]

    if zone_pid && Process.alive?(zone_pid) do
      alias DNS.Zone.Validator.Zone, as: ZoneValidator
      zone_name = socket.assigns.zone_name

      try do
        existing_records = YellowDog.Dns.Zone.Auth.get_all_records(zone_pid)

        case ZoneValidator.check_would_conflict(validated, existing_records, zone_name) do
          {:ok, :no_conflict} ->
            []

          {:error, %{message: message}} ->
            [message]

          {:error, _} ->
            []
        end
      rescue
        _ -> []
      end
    else
      []
    end
  end

  defp safe_record_type(type_str) when is_binary(type_str) and type_str in @supported_types,
    do: String.to_existing_atom(type_str)

  defp safe_record_type(_type_str), do: :a

  # Expose supported types for external use
  def supported_types, do: @supported_types
end
