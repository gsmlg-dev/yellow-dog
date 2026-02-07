defmodule YellowDog.Console.DnsLive.RrLive.Index do
  @moduledoc """
  DNS Resource Records management page with data table.
  Third level of the View -> Zone -> Records hierarchy.
  Shows resource records for a specific zone.
  """
  use YellowDog.Console, :live_view

  import YellowDog.Console.CsvHelper

  alias YellowDog.Console.Validators
  alias YellowDog.Dns.ZoneController

  @valid_zone_types ~w(auth forward stub cache rpz unknown)
  @valid_rr_types ~w(a aaaa cname mx ns txt soa srv ptr cap naptr hinfo rp loc)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, "dns:records")
    end

    {:ok,
     socket
     |> assign(:page_title, "Resource Records")
     |> assign(:service_running, dns_service_running?())
     |> assign(:view_name, nil)
     |> assign(:zone_type, nil)
     |> assign(:zone_name, nil)
     |> assign(:zone_pid, nil)
     |> assign(:rrs, [])
     |> assign(:filter, "")
     |> assign(:type_filter, "all")
     |> assign(:delete_confirm, nil)
     |> assign(:rr_form, nil)
     |> assign(:bulk_form, nil)
     |> assign(:editing_rr, nil)
     |> assign(:form_errors, %{})
     |> assign(:bulk_preview, nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  # ============================================================================
  # Action Handlers
  # ============================================================================

  defp apply_action(socket, :index, %{
         "view_name" => view_name,
         "zone_type" => zone_type,
         "zone_name" => zone_name
       }) do
    zone_type_atom = resolve_zone_type_atom(view_name, zone_type, zone_name)
    zone_pid = get_zone_pid(view_name, zone_type_atom, zone_name)

    socket
    |> assign(:page_title, "Records - #{zone_name}")
    |> assign(:view_name, view_name)
    |> assign(:zone_type, zone_type_atom)
    |> assign(:zone_name, zone_name)
    |> assign(:zone_pid, zone_pid)
    |> assign(:rr_form, nil)
    |> assign(:bulk_form, nil)
    |> assign(:editing_rr, nil)
    |> load_records()
  end

  defp apply_action(socket, :new, %{
         "view_name" => view_name,
         "zone_type" => zone_type,
         "zone_name" => zone_name
       }) do
    zone_type_atom = resolve_zone_type_atom(view_name, zone_type, zone_name)
    zone_pid = get_zone_pid(view_name, zone_type_atom, zone_name)

    socket
    |> assign(:page_title, "New Record - #{zone_name}")
    |> assign(:view_name, view_name)
    |> assign(:zone_type, zone_type_atom)
    |> assign(:zone_name, zone_name)
    |> assign(:zone_pid, zone_pid)
    |> assign(:editing_rr, nil)
    |> load_records()
  end

  defp apply_action(socket, :edit, %{
         "view_name" => view_name,
         "zone_type" => zone_type,
         "zone_name" => zone_name,
         "rr_index" => rr_index_str
       }) do
    zone_type_atom = resolve_zone_type_atom(view_name, zone_type, zone_name)
    zone_pid = get_zone_pid(view_name, zone_type_atom, zone_name)

    rr_index =
      case Integer.parse(rr_index_str) do
        {idx, ""} -> idx
        _ -> -1
      end

    socket =
      socket
      |> assign(:view_name, view_name)
      |> assign(:zone_type, zone_type_atom)
      |> assign(:zone_name, zone_name)
      |> assign(:zone_pid, zone_pid)
      |> load_records()

    case Enum.at(socket.assigns.rrs, rr_index) do
      nil ->
        socket
        |> put_flash(:error, "Resource record not found")
        |> push_navigate(to: records_path(view_name, zone_type_atom, zone_name))

      rr ->
        socket
        |> assign(:page_title, "Edit Record - #{zone_name}")
        |> assign(:editing_rr, %{index: rr_index, original: rr})
    end
  end

  defp apply_action(socket, :bulk, %{
         "view_name" => view_name,
         "zone_type" => zone_type,
         "zone_name" => zone_name
       })
       when zone_type in @valid_zone_types do
    zone_type_atom = String.to_existing_atom(zone_type)
    zone_pid = get_zone_pid(view_name, zone_type_atom, zone_name)

    form_data = %{
      "records" => ""
    }

    socket
    |> assign(:page_title, "Bulk Add Records - #{zone_name}")
    |> assign(:view_name, view_name)
    |> assign(:zone_type, zone_type_atom)
    |> assign(:zone_name, zone_name)
    |> assign(:zone_pid, zone_pid)
    |> assign(:bulk_form, to_form(form_data))
    |> assign(:bulk_preview, nil)
    |> load_records()
  end

  # ============================================================================
  # Event Handlers
  # ============================================================================

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, load_records(socket)}
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
  def handle_event("export_csv", _params, socket) do
    records =
      filtered_records(socket.assigns.rrs, socket.assigns.filter, socket.assigns.type_filter)

    csv = build_records_csv(records)
    timestamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d_%H%M%S")
    zone = socket.assigns.zone_name |> String.replace(".", "_")
    filename = "dns_records_#{zone}_#{timestamp}.csv"
    {:noreply, push_event(socket, "download_csv", %{content: csv, filename: filename})}
  end

  @impl true
  def handle_event("export_bind", _params, socket) do
    view_name = socket.assigns.view_name
    zone_type = socket.assigns.zone_type
    zone_name = socket.assigns.zone_name

    case export_zone_bind(view_name, zone_type, zone_name) do
      {:ok, content} ->
        timestamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d_%H%M%S")
        zone = zone_name |> String.replace(".", "_")
        filename = "#{zone}_#{timestamp}.zone"
        {:noreply, push_event(socket, "download_csv", %{content: content, filename: filename})}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Export failed: #{reason}")}
    end
  end

  @impl true
  def handle_event("validate_rr", %{"rr" => rr_params}, socket) do
    errors = validate_rr_fields(rr_params)
    {:noreply, assign(socket, :form_errors, errors)}
  end

  @impl true
  def handle_event("save_rr", %{"rr" => rr_params}, socket) do
    errors = validate_rr_fields(rr_params)

    if map_size(errors) > 0 do
      {:noreply, assign(socket, :form_errors, errors)}
    else
      editing = socket.assigns[:editing_rr]
      zone_name = socket.assigns.zone_name
      zone_type = socket.assigns.zone_type
      view_name = socket.assigns.view_name

      with {:ok, pid} <- find_auth_zone(view_name, zone_type, zone_name),
           {:ok, record} <- build_record(pid, zone_name, rr_params) do
        if editing do
          remove_existing_record(pid, editing.original)
        end

        :ok = YellowDog.Dns.Zone.Auth.add_record(pid, record)

        Phoenix.PubSub.broadcast(
          YellowDog.Console.PubSub,
          "dns:records",
          {:record_updated, zone_name}
        )

        rr_name = rr_params["name"]
        rr_type = rr_params["type"]
        action = if editing, do: "updated", else: "created"

        {:noreply,
         socket
         |> put_flash(:info, "Record '#{rr_name}' (#{String.upcase(rr_type)}) #{action}")
         |> push_navigate(to: records_path(view_name, zone_type, zone_name))}
      else
        {:error, reason} ->
          {:noreply, put_flash(socket, :error, reason)}
      end
    end
  end

  @impl true
  def handle_event("preview_bulk", %{"bulk" => %{"records" => records_text}}, socket) do
    preview = parse_bulk_preview(records_text, socket.assigns.zone_name)
    {:noreply, assign(socket, :bulk_preview, preview)}
  end

  @impl true
  def handle_event("bulk_add_rrs", %{"bulk" => bulk_params}, socket) do
    view_name = socket.assigns.view_name
    zone_type = socket.assigns.zone_type
    zone_name = socket.assigns.zone_name
    records_text = bulk_params["records"]

    case find_auth_zone(view_name, zone_type, zone_name) do
      {:ok, pid} ->
        # Prepend $ORIGIN so the zone parser knows the zone name
        zone_text = "$ORIGIN #{zone_name}.\n#{records_text}"

        case YellowDog.Dns.Zone.Auth.import_zone_file(pid, zone_text) do
          {:ok, stats} ->
            count = Map.get(stats, :imported, 0)

            Phoenix.PubSub.broadcast(
              YellowDog.Console.PubSub,
              "dns:records",
              {:record_updated, zone_name}
            )

            {:noreply,
             socket
             |> put_flash(:info, "Imported #{count} records successfully")
             |> push_navigate(to: records_path(view_name, zone_type, zone_name))}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Import failed: #{inspect(reason)}")}
        end

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, reason)}
    end
  end

  @impl true
  def handle_event("confirm_delete", %{"index" => index_str}, socket) do
    index =
      case Integer.parse(index_str) do
        {idx, ""} -> idx
        _ -> -1
      end

    rr = Enum.at(socket.assigns.rrs, index)

    if rr do
      {:noreply, assign(socket, :delete_confirm, %{index: index, rr: rr})}
    else
      {:noreply, put_flash(socket, :error, "Record not found")}
    end
  end

  @impl true
  def handle_event("delete_rr", _params, socket) do
    %{rr: rr} = socket.assigns.delete_confirm
    view_name = socket.assigns.view_name
    zone_type = socket.assigns.zone_type
    zone_name = socket.assigns.zone_name

    case find_auth_zone(view_name, zone_type, zone_name) do
      {:ok, pid} ->
        :ok = remove_existing_record(pid, rr)

        Phoenix.PubSub.broadcast(
          YellowDog.Console.PubSub,
          "dns:records",
          {:record_updated, zone_name}
        )

        {:noreply,
         socket
         |> assign(:delete_confirm, nil)
         |> load_records()
         |> put_flash(:info, "Record '#{rr.name}' (#{String.upcase(to_string(rr.type))}) deleted")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:delete_confirm, nil)
         |> put_flash(:error, reason)}
    end
  end

  @impl true
  def handle_event("close_modal", _params, socket) do
    {:noreply, assign(socket, :delete_confirm, nil)}
  end

  @impl true
  def handle_event("cancel", _params, socket) do
    view_name = socket.assigns.view_name
    zone_type = socket.assigns.zone_type
    zone_name = socket.assigns.zone_name
    {:noreply, push_navigate(socket, to: records_path(view_name, zone_type, zone_name))}
  end

  # ============================================================================
  # PubSub Handlers
  # ============================================================================

  @impl true
  def handle_info({:record_updated, _zone_name}, socket) do
    {:noreply, load_records(socket)}
  end

  @impl true
  def handle_info({:record_saved, validated_record}, socket) do
    # Handle save from RecordForm component
    zone_pid = socket.assigns.zone_pid
    zone_name = socket.assigns.zone_name
    zone_type = socket.assigns.zone_type
    view_name = socket.assigns.view_name
    editing = socket.assigns[:editing_rr]

    if zone_pid && Process.alive?(zone_pid) do
      # If editing, remove old record first
      if editing do
        remove_existing_record(zone_pid, editing.original)
      end

      # Build and add the new record
      record = build_record_from_validated(zone_pid, validated_record)
      :ok = YellowDog.Dns.Zone.Auth.add_record(zone_pid, record)

      # Broadcast update
      Phoenix.PubSub.broadcast(
        YellowDog.Console.PubSub,
        "dns:records",
        {:record_updated, zone_name}
      )

      action = if editing, do: "updated", else: "created"

      {:noreply,
       socket
       |> put_flash(
         :info,
         "Record '#{validated_record.name}' (#{String.upcase(to_string(validated_record.type))}) #{action}"
       )
       |> push_navigate(to: records_path(view_name, zone_type, zone_name))}
    else
      {:noreply, put_flash(socket, :error, "Zone not available")}
    end
  end

  @impl true
  def handle_info(:record_cancelled, socket) do
    # Handle cancel from RecordForm component
    view_name = socket.assigns.view_name
    zone_type = socket.assigns.zone_type
    zone_name = socket.assigns.zone_name
    {:noreply, push_navigate(socket, to: records_path(view_name, zone_type, zone_name))}
  end

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  # Resolve zone type from URL param, falling back to ZoneController lookup
  # when the URL contains "unknown" (from stale View state with string zones)
  defp resolve_zone_type_atom(view_name, zone_type_str, zone_name)
       when zone_type_str in @valid_zone_types do
    zone_type_atom = String.to_existing_atom(zone_type_str)

    if zone_type_atom == :unknown do
      try do
        ZoneController.list_zones_for_view(view_name)
        |> Enum.find_value(fn
          {type, name, _pid} when name == zone_name -> type
          _ -> nil
        end)
        |> Kernel.||(:unknown)
      rescue
        _ -> :unknown
      catch
        :exit, _ -> :unknown
      end
    else
      zone_type_atom
    end
  end

  defp resolve_zone_type_atom(_view_name, _zone_type_str, _zone_name), do: :unknown

  defp validate_rr_fields(params) do
    errors = %{}
    name = params["name"] || ""
    type = String.downcase(params["type"] || "a")
    ttl_str = params["ttl"] || ""
    rdata = params["rdata"] || ""

    # Validate record name (domain name)
    errors =
      if name != "" and name != "@" do
        case Validators.validate_domain_name(name) do
          :ok -> errors
          {:error, msg} -> Map.put(errors, :name, msg)
        end
      else
        errors
      end

    # Validate TTL
    errors =
      if ttl_str != "" do
        case Integer.parse(ttl_str) do
          {ttl_val, ""} ->
            case Validators.validate_ttl(ttl_val) do
              :ok -> errors
              {:error, msg} -> Map.put(errors, :ttl, msg)
            end

          _ ->
            Map.put(errors, :ttl, "TTL must be a non-negative integer")
        end
      else
        errors
      end

    # Validate rdata based on type
    errors =
      if rdata != "" do
        case type do
          "a" ->
            case Validators.validate_ip(rdata, :ipv4) do
              :ok -> errors
              {:error, msg} -> Map.put(errors, :rdata, msg)
            end

          "aaaa" ->
            case Validators.validate_ip(rdata, :ipv6) do
              :ok -> errors
              {:error, msg} -> Map.put(errors, :rdata, msg)
            end

          "mx" ->
            case parse_mx(rdata) do
              {:ok, _} -> errors
              {:error, msg} -> Map.put(errors, :rdata, msg)
            end

          "srv" ->
            case parse_srv(rdata) do
              {:ok, _} -> errors
              {:error, msg} -> Map.put(errors, :rdata, msg)
            end

          "cname" ->
            case Validators.validate_domain_name(rdata) do
              :ok -> errors
              {:error, msg} -> Map.put(errors, :rdata, msg)
            end

          "ns" ->
            case Validators.validate_domain_name(rdata) do
              :ok -> errors
              {:error, msg} -> Map.put(errors, :rdata, msg)
            end

          _ ->
            errors
        end
      else
        errors
      end

    errors
  end

  defp get_zone_pid(view_name, zone_type, zone_name) do
    try do
      case ZoneController.find_zone(view_name, zone_type, zone_name) do
        {:ok, pid} -> pid
        :error -> nil
      end
    rescue
      _ -> nil
    catch
      :exit, _ -> nil
    end
  end

  defp records_path(view_name, zone_type, zone_name) do
    ~p"/dns/views/#{view_name}/zones/#{zone_type}/#{zone_name}/records"
  end

  defp load_records(socket) do
    view_name = socket.assigns.view_name
    zone_type = socket.assigns.zone_type
    zone_name = socket.assigns.zone_name

    records =
      if zone_type == :auth do
        case get_auth_zone_records(view_name, zone_type, zone_name) do
          {:ok, records} -> records
          :error -> []
        end
      else
        []
      end

    assign(socket, :rrs, records)
  end

  defp get_auth_zone_records(view_name, zone_type, zone_name) do
    try do
      case ZoneController.find_zone(view_name, zone_type, zone_name) do
        {:ok, pid} ->
          records =
            YellowDog.Dns.Zone.Auth.get_all_records(pid)
            |> Enum.map(fn record ->
              %{
                name: format_record_name(record.name),
                type: normalize_record_type(record.type),
                ttl: record.ttl,
                class: record.class,
                rdata: format_rdata(normalize_record_type(record.type), extract_rdata(record))
              }
            end)
            |> Enum.sort_by(fn r -> {r.name, record_type_order(r.type)} end)

          {:ok, records}

        :error ->
          :error
      end
    rescue
      _ -> :error
    catch
      :exit, _ -> :error
    end
  end

  # ============================================================================
  # Filtering
  # ============================================================================

  def filtered_records(records, filter, type_filter) do
    records
    |> filter_by_name(filter)
    |> filter_by_type(type_filter)
  end

  defp filter_by_name(records, ""), do: records
  defp filter_by_name(records, nil), do: records

  defp filter_by_name(records, filter) do
    filter_lower = String.downcase(filter)

    Enum.filter(records, fn r ->
      String.downcase(r.name) |> String.contains?(filter_lower)
    end)
  end

  defp filter_by_type(records, "all"), do: records

  defp filter_by_type(records, type_str) when type_str in @valid_rr_types do
    type = String.to_existing_atom(type_str)
    Enum.filter(records, fn r -> r.type == type end)
  end

  defp filter_by_type(records, _type_str), do: records

  def unique_record_types(records) do
    records
    |> Enum.map(& &1.type)
    |> Enum.uniq()
    |> Enum.sort_by(&record_type_order/1)
  end

  # ============================================================================
  # Bulk Preview
  # ============================================================================

  @doc "Parses zone text and returns a preview map. Public for testability."
  def parse_bulk_preview("", _zone_name), do: nil
  def parse_bulk_preview(nil, _zone_name), do: nil

  def parse_bulk_preview(text, zone_name) do
    zone_text = "$ORIGIN #{zone_name}.\n#{text}"

    case DNS.Zone.parse_zone_string(zone_text) do
      {:ok, zone} ->
        records = zone.records || []

        record_details =
          Enum.flat_map(records, fn rrset ->
            data_list = if is_list(rrset.data), do: rrset.data, else: [rrset.data]

            Enum.map(data_list, fn _d ->
              %{
                name: format_rrset_name(rrset.name),
                type: String.upcase(to_string(rrset.type)),
                ttl: rrset.ttl
              }
            end)
          end)

        type_counts =
          record_details
          |> Enum.frequencies_by(& &1.type)

        %{
          status: :ok,
          count: length(record_details),
          types: type_counts,
          records: record_details
        }

      {:error, reason} ->
        %{status: :error, message: to_string(reason)}
    end
  end

  defp format_rrset_name(name) when is_binary(name), do: name
  defp format_rrset_name(%DNS.Message.Domain{} = d), do: to_string(d)
  defp format_rrset_name(name), do: to_string(name)

  # ============================================================================
  # BIND Zone Export
  # ============================================================================

  defp export_zone_bind(view_name, :auth, zone_name) do
    try do
      case ZoneController.find_zone(view_name, :auth, zone_name) do
        {:ok, pid} ->
          YellowDog.Dns.Zone.Auth.export_zone_file(pid)

        :error ->
          {:error, "Zone not found"}
      end
    rescue
      _ -> {:error, "Zone not available"}
    catch
      :exit, _ -> {:error, "Zone not available"}
    end
  end

  defp export_zone_bind(_view_name, _zone_type, _zone_name) do
    {:error, "Only authoritative zones can be exported as BIND format"}
  end

  # ============================================================================
  # CSV Export
  # ============================================================================

  defp build_records_csv(records) do
    header = "Name,Type,TTL,Data\r\n"

    rows =
      Enum.map_join(records, "\r\n", fn rr ->
        [
          csv_escape(rr.name),
          csv_escape(String.upcase(to_string(rr.type))),
          to_string(rr.ttl),
          csv_escape(rr.rdata)
        ]
        |> Enum.join(",")
      end)

    header <> rows
  end

  # ============================================================================
  # Formatting
  # ============================================================================

  def record_type_badge(:a), do: "primary"
  def record_type_badge(:aaaa), do: "primary"
  def record_type_badge(:cname), do: "secondary"
  def record_type_badge(:ns), do: "accent"
  def record_type_badge(:mx), do: "info"
  def record_type_badge(:txt), do: "warning"
  def record_type_badge(:soa), do: "success"
  def record_type_badge(:srv), do: "info"
  def record_type_badge(:ptr), do: "accent"
  def record_type_badge(_), do: "ghost"

  defp record_type_order(:soa), do: 0
  defp record_type_order(:ns), do: 1
  defp record_type_order(:a), do: 2
  defp record_type_order(:aaaa), do: 3
  defp record_type_order(:cname), do: 4
  defp record_type_order(:mx), do: 5
  defp record_type_order(:txt), do: 6
  defp record_type_order(:srv), do: 7
  defp record_type_order(:ptr), do: 8
  defp record_type_order(_), do: 99

  defp format_record_name(%DNS.Message.Domain{} = domain), do: to_string(domain)
  defp format_record_name(name) when is_binary(name), do: name
  defp format_record_name(name), do: to_string(name)

  defp normalize_record_type(%DNS.ResourceRecordType{} = type) do
    type
    |> to_string()
    |> String.downcase()
    |> safe_type_atom()
  end

  defp normalize_record_type(type) when is_binary(type) do
    type
    |> String.downcase()
    |> safe_type_atom()
  end

  defp normalize_record_type(type) when is_atom(type), do: type
  defp normalize_record_type(type), do: type

  defp safe_type_atom(type_str) when type_str in @valid_rr_types,
    do: String.to_existing_atom(type_str)

  defp safe_type_atom(type_str) do
    try do
      String.to_existing_atom(type_str)
    rescue
      ArgumentError -> String.to_atom("unknown_#{type_str}")
    end
  end

  defp extract_rdata(%{rdata: rdata}), do: rdata
  defp extract_rdata(%{data: data}), do: data
  defp extract_rdata(_record), do: nil

  defp format_rdata(:a, rdata), do: format_ipv4(rdata)
  defp format_rdata(:aaaa, rdata), do: format_ipv6(rdata)
  defp format_rdata(:cname, rdata), do: format_domain(rdata)
  defp format_rdata(:ns, rdata), do: format_domain(rdata)
  defp format_rdata(:ptr, rdata), do: format_domain(rdata)
  defp format_rdata(:mx, rdata), do: format_mx(rdata)
  defp format_rdata(:txt, rdata), do: format_txt(rdata)
  defp format_rdata(:soa, rdata), do: format_soa(rdata)
  defp format_rdata(:srv, rdata), do: format_srv(rdata)
  defp format_rdata(_type, rdata), do: to_string(rdata)

  defp format_ipv4(%{address: addr}) when is_tuple(addr), do: :inet.ntoa(addr) |> to_string()
  defp format_ipv4(addr) when is_tuple(addr), do: :inet.ntoa(addr) |> to_string()
  defp format_ipv4(rdata), do: to_string(rdata)

  defp format_ipv6(%{address: addr}) when is_tuple(addr), do: :inet.ntoa(addr) |> to_string()
  defp format_ipv6(addr) when is_tuple(addr), do: :inet.ntoa(addr) |> to_string()
  defp format_ipv6(rdata), do: to_string(rdata)

  defp format_domain(%{name: name}), do: to_string(name)
  defp format_domain(%DNS.Message.Domain{} = domain), do: to_string(domain)
  defp format_domain(name) when is_binary(name), do: name
  defp format_domain(rdata), do: to_string(rdata)

  defp format_mx(%{preference: pref, exchange: exchange}),
    do: "#{pref} #{format_domain(exchange)}"

  defp format_mx(rdata), do: to_string(rdata)

  defp format_txt(%{txt_data: data}) when is_list(data), do: Enum.join(data, " ")
  defp format_txt(%{txt_data: data}) when is_binary(data), do: data
  defp format_txt(data) when is_binary(data), do: data
  defp format_txt(rdata), do: to_string(rdata)

  defp format_soa(%{mname: mname, rname: rname, serial: serial}) do
    "#{format_domain(mname)} #{format_domain(rname)} #{serial}"
  end

  defp format_soa(rdata), do: to_string(rdata)

  defp format_srv(%{priority: priority, weight: weight, port: port, target: target}) do
    "#{priority} #{weight} #{port} #{format_domain(target)}"
  end

  defp format_srv(rdata), do: to_string(rdata)

  defp find_auth_zone(view_name, :auth, zone_name) do
    case ZoneController.find_zone(view_name, :auth, zone_name) do
      {:ok, pid} -> {:ok, pid}
      :error -> {:error, "Authoritative zone not found: #{zone_name}"}
    end
  end

  defp find_auth_zone(_view_name, _zone_type, zone_name) do
    {:error, "Zone '#{zone_name}' is not authoritative"}
  end

  defp build_record(pid, zone_name, rr_params) do
    format = detect_record_format(pid)

    name =
      rr_params
      |> Map.get("name", "")
      |> normalize_record_name(zone_name)

    type_str =
      rr_params
      |> Map.get("type", "a")
      |> String.downcase()

    type =
      if type_str in @valid_rr_types,
        do: String.to_existing_atom(type_str),
        else: :a

    ttl = parse_ttl(Map.get(rr_params, "ttl", "3600"))
    rdata_input = Map.get(rr_params, "rdata", "")

    with {:ok, ttl_value} <- ttl,
         {:ok, rdata} <- parse_rdata(type, rdata_input, format) do
      {:ok, build_record_struct(format, name, type, ttl_value, rdata)}
    else
      {:error, _} = error -> error
    end
  end

  defp detect_record_format(pid) do
    case YellowDog.Dns.Zone.Auth.get_all_records(pid) do
      [%DNS.Message.Record{} | _] -> :dns_message_record
      [%DNS.Zone.Parser.ResourceRecord{} | _] -> :parser_record
      [%{rdata: _} | _] -> :map_record
      _ -> :dns_message_record
    end
  end

  # Build record from validated RecordValidator output
  defp build_record_from_validated(pid, validated) do
    format = detect_record_format(pid)
    build_record_struct(format, validated.name, validated.type, validated.ttl, validated.rdata)
  end

  defp build_record_struct(:dns_message_record, name, type, ttl, rdata) do
    DNS.Message.Record.new(name, type, :in, ttl, rdata)
  end

  defp build_record_struct(:parser_record, name, type, ttl, rdata) do
    %DNS.Zone.Parser.ResourceRecord{
      name: name,
      ttl: ttl,
      class: "IN",
      type: String.upcase(to_string(type)),
      rdata: rdata
    }
  end

  defp build_record_struct(:map_record, name, type, ttl, rdata) do
    %{name: name, type: type, class: :in, ttl: ttl, rdata: rdata}
  end

  defp normalize_record_name(name, zone_name) do
    trimmed = String.trim(to_string(name || ""))

    cond do
      trimmed in ["", "@"] -> zone_name
      String.ends_with?(trimmed, ".") -> String.trim_trailing(trimmed, ".")
      String.ends_with?(trimmed, zone_name) -> trimmed
      String.contains?(trimmed, ".") -> trimmed
      true -> "#{trimmed}.#{zone_name}"
    end
  end

  defp parse_ttl(ttl) when is_integer(ttl) and ttl >= 0, do: {:ok, ttl}

  defp parse_ttl(ttl) when is_binary(ttl) do
    ttl
    |> String.trim()
    |> Integer.parse()
    |> case do
      {value, ""} when value >= 0 -> {:ok, value}
      _ -> {:error, "TTL must be a non-negative integer"}
    end
  end

  defp parse_ttl(_ttl), do: {:error, "TTL must be a non-negative integer"}

  defp parse_rdata(type, value, format) do
    value = String.trim(to_string(value || ""))

    cond do
      value == "" ->
        {:error, "Record data cannot be empty"}

      true ->
        do_parse_rdata(type, value, format)
    end
  end

  defp do_parse_rdata(:a, value, :parser_record), do: {:ok, value}

  defp do_parse_rdata(:a, value, _format) do
    parse_ip(value, 4, "IPv4")
  end

  defp do_parse_rdata(:aaaa, value, :parser_record), do: {:ok, value}

  defp do_parse_rdata(:aaaa, value, _format) do
    parse_ip(value, 8, "IPv6")
  end

  defp do_parse_rdata(:cname, value, _format), do: {:ok, value}
  defp do_parse_rdata(:ns, value, _format), do: {:ok, value}
  defp do_parse_rdata(:ptr, value, _format), do: {:ok, value}

  defp do_parse_rdata(:txt, value, _format) do
    {:ok, [strip_quotes(value)]}
  end

  defp do_parse_rdata(:mx, value, :parser_record) do
    with {:ok, {pref, exchange}} <- parse_mx(value) do
      {:ok, %DNS.Zone.Parser.MXRecord{priority: pref, exchange: exchange}}
    end
  end

  defp do_parse_rdata(:mx, value, _format), do: parse_mx(value)

  defp do_parse_rdata(:srv, value, :parser_record) do
    with {:ok, {priority, weight, port, target}} <- parse_srv(value) do
      {:ok,
       %DNS.Zone.Parser.SRVRecord{priority: priority, weight: weight, port: port, target: target}}
    end
  end

  defp do_parse_rdata(:srv, value, _format), do: parse_srv(value)

  defp do_parse_rdata(_type, value, _format), do: {:ok, value}

  defp parse_ip(value, size, label) do
    case :inet.parse_address(String.to_charlist(value)) do
      {:ok, addr} when tuple_size(addr) == size ->
        {:ok, addr}

      _ ->
        {:error, "#{label} address is invalid"}
    end
  end

  defp parse_mx(value) do
    case String.split(value, ~r/\\s+/, parts: 2) do
      [pref_str, exchange] ->
        case Integer.parse(pref_str) do
          {pref, ""} -> {:ok, {pref, String.trim(exchange)}}
          _ -> {:error, "MX preference must be an integer"}
        end

      _ ->
        {:error, "MX data must be: <preference> <exchange>"}
    end
  end

  defp parse_srv(value) do
    case String.split(value, ~r/\\s+/, parts: 4) do
      [priority_str, weight_str, port_str, target] ->
        with {priority, ""} <- Integer.parse(priority_str),
             {weight, ""} <- Integer.parse(weight_str),
             {port, ""} <- Integer.parse(port_str) do
          {:ok, {priority, weight, port, String.trim(target)}}
        else
          _ -> {:error, "SRV fields must be integers (priority weight port)"}
        end

      _ ->
        {:error, "SRV data must be: <priority> <weight> <port> <target>"}
    end
  end

  defp strip_quotes(value) do
    trimmed = String.trim(value)

    if String.starts_with?(trimmed, "\"") and String.ends_with?(trimmed, "\"") do
      trimmed
      |> String.trim_leading("\"")
      |> String.trim_trailing("\"")
    else
      trimmed
    end
  end

  defp remove_existing_record(_pid, %{name: nil}), do: :ok

  defp remove_existing_record(pid, %{name: name, type: type}) do
    YellowDog.Dns.Zone.Auth.remove_record(pid, name, normalize_record_type(type))
  end

  defp dns_service_running?, do: Process.whereis(YellowDog.Dns) != nil
end
