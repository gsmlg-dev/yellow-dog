defmodule YellowDog.Console.DnsLive.AclLive do
  @moduledoc """
  DNS ACL management page for configuring view access control lists.
  Supports built-in ACLs (any, none, localhost, localnets, geo) and custom rules.
  Also supports creating and managing named ACLs.
  """
  use YellowDog.Console, :live_view

  alias YellowDog.Console.Validators
  alias YellowDog.Dns.View
  alias YellowDog.Dns.ViewManager
  alias YellowDog.Dns.View.ACL
  alias YellowDog.Dns.AclRegistry

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, "dns:views")
      Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, "dns:acls")
    end

    {:ok,
     socket
     |> assign(:page_title, "DNS ACL")
     |> assign(:views, list_views_with_acl())
     |> assign(:named_acls, list_named_acls())
     |> assign(:builtin_acls, ACL.list_builtins())
     |> assign(:countries, GeoIpDb.list_countries())
     |> assign(:selected_countries, [])
     |> assign(:country_search, "")
     |> assign(:editing_view, nil)
     |> assign(:show_create_form, false)
     |> assign(:editing_acl, nil)
     |> assign(:delete_confirm, nil)
     |> assign(:acl_form, to_form(%{"acl_type" => "any", "rules" => ""}))
     |> assign(
       :create_form,
       to_form(%{"name" => "", "description" => "", "acl_type" => "custom", "rules" => ""})
     )
     |> assign(:filter, "")
     |> assign(:type_filter, "all")
     |> assign(:form_errors, %{})}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply,
     socket
     |> assign(:views, list_views_with_acl())
     |> assign(:named_acls, list_named_acls())}
  end

  @impl true
  def handle_event("filter", %{"filter" => filter}, socket) do
    {:noreply, assign(socket, :filter, filter)}
  end

  @impl true
  def handle_event("filter_type", %{"type" => type}, socket) do
    {:noreply, assign(socket, :type_filter, type)}
  end

  @impl true
  def handle_event("show_create_form", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_create_form, true)
     |> assign(:editing_acl, nil)
     |> assign(:selected_countries, [])
     |> assign(:country_search, "")
     |> assign(:form_errors, %{})
     |> assign(
       :create_form,
       to_form(%{"name" => "", "description" => "", "acl_type" => "custom", "rules" => ""})
     )}
  end

  @impl true
  def handle_event("close_create_form", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_create_form, false)
     |> assign(:editing_acl, nil)
     |> assign(:selected_countries, [])
     |> assign(:country_search, "")}
  end

  @impl true
  def handle_event("edit_named_acl", %{"name" => name}, socket) do
    result =
      try do
        AclRegistry.get_acl(name)
      catch
        :exit, _ -> {:error, :service_unavailable}
      end

    case result do
      {:ok, acl} ->
        {acl_type, selected_countries} = parse_named_acl_for_form(acl)

        create_form =
          to_form(%{
            "name" => acl.name,
            "description" => acl.description || "",
            "acl_type" => acl_type,
            "rules" => format_named_acl_rules(acl.rules)
          })

        {:noreply,
         socket
         |> assign(:show_create_form, true)
         |> assign(:editing_acl, name)
         |> assign(:selected_countries, selected_countries)
         |> assign(:country_search, "")
         |> assign(:create_form, create_form)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "ACL not found")}
    end
  end

  @impl true
  def handle_event("create_type_changed", %{"acl" => %{"acl_type" => acl_type}}, socket) do
    form = socket.assigns.create_form

    create_form =
      to_form(%{
        "name" => form[:name].value,
        "description" => form[:description].value,
        "acl_type" => acl_type,
        "rules" => form[:rules].value
      })

    {:noreply, assign(socket, :create_form, create_form)}
  end

  @impl true
  def handle_event("validate_named_acl", %{"acl" => params}, socket) do
    errors = validate_acl_fields(params)
    {:noreply, assign(socket, :form_errors, errors)}
  end

  @impl true
  def handle_event("save_named_acl", %{"acl" => params}, socket) do
    name = String.trim(params["name"] || "")
    description = params["description"] || ""
    acl_type = params["acl_type"]

    errors = validate_acl_fields(params)

    if map_size(errors) > 0 do
      {:noreply, assign(socket, :form_errors, errors)}
    else
      if name == "" do
        {:noreply, put_flash(socket, :error, "ACL name is required")}
      else
        rules =
          build_named_acl_rules(acl_type, params["rules"], socket.assigns.selected_countries)

        acl = %{
          name: name,
          description: description,
          rules: rules
        }

        result =
          try do
            if socket.assigns.editing_acl do
              AclRegistry.update_acl(socket.assigns.editing_acl, acl)
            else
              AclRegistry.create_acl(acl)
            end
          catch
            :exit, _ -> {:error, :service_unavailable}
          end

        case result do
          :ok ->
            action = if socket.assigns.editing_acl, do: "updated", else: "created"

            {:noreply,
             socket
             |> assign(:named_acls, list_named_acls())
             |> assign(:show_create_form, false)
             |> assign(:editing_acl, nil)
             |> assign(:selected_countries, [])
             |> assign(:country_search, "")
             |> put_flash(:info, "ACL '#{name}' #{action} successfully")}

          {:error, :already_exists} ->
            {:noreply, put_flash(socket, :error, "ACL '#{name}' already exists")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Failed to save ACL: #{inspect(reason)}")}
        end
      end
    end
  end

  @impl true
  def handle_event("confirm_delete_acl", %{"name" => name}, socket) do
    {:noreply, assign(socket, :delete_confirm, name)}
  end

  @impl true
  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, :delete_confirm, nil)}
  end

  @impl true
  def handle_event("delete_named_acl", _params, socket) do
    name = socket.assigns.delete_confirm

    result =
      try do
        AclRegistry.delete_acl(name)
      catch
        :exit, _ -> {:error, :service_unavailable}
      end

    case result do
      :ok ->
        {:noreply,
         socket
         |> assign(:named_acls, list_named_acls())
         |> assign(:delete_confirm, nil)
         |> put_flash(:info, "ACL '#{name}' deleted successfully")}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:delete_confirm, nil)
         |> put_flash(:error, "ACL '#{name}' not found")}
    end
  end

  @impl true
  def handle_event("edit_acl", %{"view" => view_name}, socket) do
    view = Enum.find(socket.assigns.views, fn v -> v.name == view_name end)

    if view do
      # Extract selected countries if geo type
      selected_countries =
        if view.acl_type == "geo" do
          extract_geo_countries(view.acl_rules)
        else
          []
        end

      acl_form =
        to_form(%{
          "acl_type" => view.acl_type,
          "rules" => format_acl_rules(view.acl_rules)
        })

      {:noreply,
       socket
       |> assign(:editing_view, view)
       |> assign(:selected_countries, selected_countries)
       |> assign(:country_search, "")
       |> assign(:acl_form, acl_form)}
    else
      {:noreply, put_flash(socket, :error, "View not found")}
    end
  end

  @impl true
  def handle_event("close_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_view, nil)
     |> assign(:selected_countries, [])
     |> assign(:country_search, "")}
  end

  @impl true
  def handle_event("toggle_country", %{"code" => code}, socket) do
    selected = socket.assigns.selected_countries

    updated =
      if code in selected do
        List.delete(selected, code)
      else
        [code | selected]
      end

    {:noreply, assign(socket, :selected_countries, Enum.sort(updated))}
  end

  @impl true
  def handle_event("search_country", %{"search" => search}, socket) do
    {:noreply, assign(socket, :country_search, search)}
  end

  @impl true
  def handle_event("clear_country_search", _params, socket) do
    {:noreply, assign(socket, :country_search, "")}
  end

  @impl true
  def handle_event("acl_type_changed", %{"acl" => %{"acl_type" => acl_type}}, socket) do
    acl_form =
      to_form(%{"acl_type" => acl_type, "rules" => socket.assigns.acl_form[:rules].value})

    {:noreply, assign(socket, :acl_form, acl_form)}
  end

  @impl true
  def handle_event("save_acl", %{"acl" => params}, socket) do
    view_name = socket.assigns.editing_view.name
    acl_type = params["acl_type"]

    acl_config =
      case acl_type do
        "any" -> :any
        "none" -> :none
        "localhost" -> "localhost"
        "localnets" -> "localnets"
        "geo" -> [{:allow, {:geo, socket.assigns.selected_countries}}]
        "custom" -> parse_acl_rules(params["rules"] || "")
      end

    result =
      try do
        ViewManager.get_view(view_name)
      catch
        :exit, _ -> :error
      end

    case result do
      {:ok, pid} ->
        try do
          View.reload(pid, %{acl: acl_config})
        catch
          :exit, _ -> :ok
        end

        {:noreply,
         socket
         |> assign(:views, list_views_with_acl())
         |> assign(:editing_view, nil)
         |> assign(:selected_countries, [])
         |> assign(:country_search, "")
         |> put_flash(:info, "ACL updated for view '#{view_name}'")}

      :error ->
        {:noreply, put_flash(socket, :error, "View not found")}
    end
  end

  @impl true
  def handle_event("export_csv", _params, socket) do
    acls = socket.assigns.named_acls
    csv = build_csv(acls)
    filename = "dns_acls_#{Calendar.strftime(DateTime.utc_now(), "%Y%m%d_%H%M%S")}.csv"

    {:noreply, push_event(socket, "download_csv", %{content: csv, filename: filename})}
  end

  @impl true
  def handle_info({:view_updated, _view_name}, socket) do
    {:noreply, assign(socket, :views, list_views_with_acl())}
  end

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # Data fetching functions

  defp list_views_with_acl do
    try do
      views = ViewManager.list_views()

      Enum.map(views, fn {view_name, pid, priority} ->
        stats = View.stats(pid)
        {acl_type, acl_rules} = parse_acl_config(stats)

        %{
          name: view_name,
          priority: priority,
          acl_type: acl_type,
          acl_rules: acl_rules
        }
      end)
      |> Enum.sort_by(& &1.priority)
    rescue
      _ -> []
    catch
      :exit, _ -> []
    end
  end

  defp parse_acl_config(stats) do
    acl = Map.get(stats, :acl)

    case acl do
      :any -> {"any", []}
      :none -> {"none", []}
      "localhost" -> {"localhost", []}
      "localnets" -> {"localnets", []}
      rules when is_list(rules) -> categorize_rules(rules)
      %ACL{rules: rules} -> categorize_rules(rules)
      _ -> {"any", []}
    end
  end

  defp categorize_rules(rules) do
    # Check if rules contain geo rules
    has_geo =
      Enum.any?(rules, fn
        {:allow, {:geo, _}} -> true
        {:deny, {:geo, _}} -> true
        _ -> false
      end)

    if has_geo do
      {"geo", rules}
    else
      {"custom", rules}
    end
  end

  defp extract_geo_countries(rules) when is_list(rules) do
    rules
    |> Enum.flat_map(fn
      {:allow, {:geo, countries}} -> countries
      {:deny, {:geo, countries}} -> countries
      _ -> []
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp extract_geo_countries(_), do: []

  # ACL formatting functions

  defp format_acl_rules(rules) when is_list(rules) do
    rules
    |> Enum.map(&format_acl_rule/1)
    |> Enum.join("\n")
  end

  defp format_acl_rules(_), do: ""

  defp format_acl_rule({:allow, ip, prefix}) when is_tuple(ip) do
    "allow #{:inet.ntoa(ip) |> to_string()}/#{prefix}"
  end

  defp format_acl_rule({:deny, ip, prefix}) when is_tuple(ip) do
    "deny #{:inet.ntoa(ip) |> to_string()}/#{prefix}"
  end

  defp format_acl_rule({:allow, cidr}) when is_binary(cidr), do: "allow #{cidr}"
  defp format_acl_rule({:deny, cidr}) when is_binary(cidr), do: "deny #{cidr}"
  defp format_acl_rule({:allow, :any}), do: "allow any"
  defp format_acl_rule({:deny, :any}), do: "deny any"
  defp format_acl_rule({:allow, {:geo, countries}}), do: "allow geo #{Enum.join(countries, ", ")}"
  defp format_acl_rule({:deny, {:geo, countries}}), do: "deny geo #{Enum.join(countries, ", ")}"
  defp format_acl_rule(rule), do: inspect(rule)

  defp parse_acl_rules(text) when is_binary(text) do
    text
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&parse_acl_rule_line/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_acl_rule_line(line) do
    case String.split(line, ~r/\s+/, parts: 2) do
      ["allow", target] -> {:allow, parse_acl_target(target)}
      ["deny", target] -> {:deny, parse_acl_target(target)}
      _ -> nil
    end
  end

  defp parse_acl_target("any"), do: :any

  defp parse_acl_target(target) do
    # Could be IP, CIDR, or named ACL
    target
  end

  defp acl_type_label("any"), do: "Allow All"
  defp acl_type_label("none"), do: "Deny All"
  defp acl_type_label("localhost"), do: "Localhost Only"
  defp acl_type_label("localnets"), do: "Local Networks"
  defp acl_type_label("geo"), do: "Geographic"
  defp acl_type_label("custom"), do: "Custom Rules"
  defp acl_type_label(_), do: "Unknown"

  defp acl_type_badge("any"), do: "success"
  defp acl_type_badge("none"), do: "error"
  defp acl_type_badge("localhost"), do: "warning"
  defp acl_type_badge("localnets"), do: "info"
  defp acl_type_badge("geo"), do: "secondary"
  defp acl_type_badge("custom"), do: "primary"
  defp acl_type_badge(_), do: "ghost"

  defp filtered_countries(countries, "") do
    countries
  end

  defp filtered_countries(countries, search) do
    search_lower = String.downcase(search)

    Enum.filter(countries, fn %{code: code, name: name} ->
      String.contains?(String.downcase(name), search_lower) or
        String.contains?(String.downcase(code), search_lower)
    end)
  end

  # Named ACL functions

  defp validate_acl_fields(params) do
    errors = %{}
    name = String.trim(params["name"] || "")
    acl_type = params["acl_type"]
    rules = params["rules"] || ""

    # Validate ACL name (alphanumeric, hyphens, underscores)
    errors =
      if name != "" and not Regex.match?(~r/^[a-zA-Z0-9_-]+$/, name) do
        Map.put(errors, :name, "Name must be alphanumeric with hyphens or underscores")
      else
        errors
      end

    # Validate custom rules contain valid CIDR/IP entries
    errors =
      if acl_type == "custom" and rules != "" do
        invalid =
          rules
          |> String.split("\n")
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.find(fn line ->
            case String.split(line, ~r/\s+/, parts: 2) do
              [action, target] when action in ["allow", "deny"] ->
                target != "any" and
                  Validators.validate_cidr(target, :ipv4) != :ok and
                  Validators.validate_cidr(target, :ipv6) != :ok and
                  Validators.validate_ip(target, :ipv4) != :ok and
                  Validators.validate_ip(target, :ipv6) != :ok

              _ ->
                true
            end
          end)

        if invalid do
          Map.put(errors, :rules, "Invalid rule: #{invalid}")
        else
          errors
        end
      else
        errors
      end

    errors
  end

  defp list_named_acls do
    try do
      AclRegistry.list_acls()
    rescue
      _ -> []
    catch
      :exit, _ -> []
    end
  end

  defp parse_named_acl_for_form(acl) do
    rules = acl.rules || []

    # Check if rules contain geo rules
    geo_countries =
      Enum.flat_map(rules, fn
        %{geo_countries: countries} when is_list(countries) -> countries
        _ -> []
      end)

    if length(geo_countries) > 0 do
      {"geo", Enum.sort(Enum.uniq(geo_countries))}
    else
      {"custom", []}
    end
  end

  defp format_named_acl_rules(rules) when is_list(rules) do
    rules
    |> Enum.map(&format_named_acl_rule/1)
    |> Enum.join("\n")
  end

  defp format_named_acl_rules(_), do: ""

  defp format_named_acl_rule(%{action: action, network: network}) when is_binary(network) do
    "#{action} #{network}"
  end

  defp format_named_acl_rule(%{action: action, geo_countries: countries})
       when is_list(countries) do
    "#{action} geo #{Enum.join(countries, ", ")}"
  end

  defp format_named_acl_rule(%{action: action}) do
    "#{action} any"
  end

  defp format_named_acl_rule(_), do: ""

  defp build_named_acl_rules("geo", _rules_text, selected_countries)
       when selected_countries != [] do
    [%{action: "allow", geo_countries: selected_countries}]
  end

  defp build_named_acl_rules("custom", rules_text, _selected_countries) do
    rules_text
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&parse_named_acl_rule_line/1)
    |> Enum.reject(&is_nil/1)
  end

  defp build_named_acl_rules(_, _, _), do: []

  defp parse_named_acl_rule_line(line) do
    case String.split(line, ~r/\s+/, parts: 2) do
      ["allow", target] -> build_rule("allow", target)
      ["deny", target] -> build_rule("deny", target)
      _ -> nil
    end
  end

  defp build_rule(action, "any"), do: %{action: action}

  defp build_rule(action, "geo " <> countries_str) do
    countries =
      countries_str
      |> String.split(~r/[,\s]+/)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    %{action: action, geo_countries: countries}
  end

  defp build_rule(action, network), do: %{action: action, network: network}

  def filtered_named_acls(acls, filter, _type_filter) do
    acls
    |> filter_acls_by_name(filter)
  end

  defp filter_acls_by_name(acls, ""), do: acls

  defp filter_acls_by_name(acls, filter) do
    filter_lower = String.downcase(filter)

    Enum.filter(acls, fn acl ->
      String.contains?(String.downcase(acl.name), filter_lower) or
        String.contains?(String.downcase(acl.description || ""), filter_lower)
    end)
  end

  def filtered_views_acl(views, filter, type_filter) do
    views
    |> filter_views_by_name(filter)
    |> filter_views_by_acl_type(type_filter)
  end

  defp filter_views_by_name(views, ""), do: views

  defp filter_views_by_name(views, filter) do
    filter_lower = String.downcase(filter)

    Enum.filter(views, fn view ->
      String.contains?(String.downcase(view.name), filter_lower)
    end)
  end

  defp filter_views_by_acl_type(views, "all"), do: views

  defp filter_views_by_acl_type(views, type) do
    Enum.filter(views, fn view -> view.acl_type == type end)
  end

  def unique_acl_types(views) do
    views
    |> Enum.map(& &1.acl_type)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp build_csv(acls) do
    header = "Name,Description,Rules\r\n"

    rows =
      Enum.map_join(acls, "\r\n", fn acl ->
        [
          csv_escape(acl.name),
          csv_escape(acl.description || ""),
          csv_escape(format_acl_rules_for_csv(acl.rules))
        ]
        |> Enum.join(",")
      end)

    header <> rows
  end

  defp csv_escape(str) do
    if String.contains?(str, [",", "\"", "\n"]) do
      "\"" <> String.replace(str, "\"", "\"\"") <> "\""
    else
      str
    end
  end

  defp format_acl_rules_for_csv(rules) when is_list(rules) do
    rules
    |> Enum.map(&format_named_acl_rule/1)
    |> Enum.join("; ")
  end

  defp format_acl_rules_for_csv(_), do: ""
end
