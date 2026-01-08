defmodule YellowDog.Console.DnsLive.AclLive do
  @moduledoc """
  DNS ACL management page for configuring view access control lists.
  Supports built-in ACLs (any, none, localhost, localnets) and custom rules.
  """
  use YellowDog.Console, :live_view

  alias YellowDog.Dns.View
  alias YellowDog.Dns.ViewManager
  alias YellowDog.Dns.View.ACL

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, "dns:views")
    end

    {:ok,
     socket
     |> assign(:page_title, "DNS ACL")
     |> assign(:views, list_views_with_acl())
     |> assign(:builtin_acls, ACL.list_builtins())
     |> assign(:editing_view, nil)
     |> assign(:acl_form, to_form(%{"acl_type" => "any", "rules" => ""}))}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, assign(socket, :views, list_views_with_acl())}
  end

  @impl true
  def handle_event("edit_acl", %{"view" => view_name}, socket) do
    view = Enum.find(socket.assigns.views, fn v -> v.name == view_name end)

    if view do
      acl_form =
        to_form(%{
          "acl_type" => view.acl_type,
          "rules" => format_acl_rules(view.acl_rules)
        })

      {:noreply,
       socket
       |> assign(:editing_view, view)
       |> assign(:acl_form, acl_form)}
    else
      {:noreply, put_flash(socket, :error, "View not found")}
    end
  end

  @impl true
  def handle_event("close_modal", _params, socket) do
    {:noreply, assign(socket, :editing_view, nil)}
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
        "custom" -> parse_acl_rules(params["rules"] || "")
      end

    case ViewManager.get_view(view_name) do
      {:ok, pid} ->
        View.reload(pid, %{acl: acl_config})

        {:noreply,
         socket
         |> assign(:views, list_views_with_acl())
         |> assign(:editing_view, nil)
         |> put_flash(:info, "ACL updated for view '#{view_name}'")}

      :error ->
        {:noreply, put_flash(socket, :error, "View not found")}
    end
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
    end
  end

  defp parse_acl_config(stats) do
    acl = Map.get(stats, :acl)

    case acl do
      :any -> {"any", []}
      :none -> {"none", []}
      "localhost" -> {"localhost", []}
      "localnets" -> {"localnets", []}
      rules when is_list(rules) -> {"custom", rules}
      %ACL{rules: rules} -> {"custom", rules}
      _ -> {"any", []}
    end
  end

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
  defp acl_type_label("custom"), do: "Custom Rules"
  defp acl_type_label(_), do: "Unknown"

  defp acl_type_badge("any"), do: "success"
  defp acl_type_badge("none"), do: "error"
  defp acl_type_badge("localhost"), do: "warning"
  defp acl_type_badge("localnets"), do: "info"
  defp acl_type_badge("custom"), do: "primary"
  defp acl_type_badge(_), do: "ghost"
end
