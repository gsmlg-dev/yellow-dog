defmodule YellowDog.ManagementUI.DnsSettings do
  @moduledoc false
  use YellowDog.ManagementUI, :html

  @transports [
    {"udp", "UDP", 53},
    {"tcp", "TCP", 53},
    {"dot", "DoT", 853},
    {"doq", "DoQ", 853},
    {"doh", "DoH", 443}
  ]
  @modes [
    {"All IP addresses", "all"},
    {"All IPv4", "all_ipv4"},
    {"All IPv6", "all_ipv6"},
    {"Specific IP addresses", "specific"}
  ]
  @policy_fields ~w(recursion allow_query forward_zones)

  def form_params(service) do
    config = (service && service["config"]) || %{}
    listen = config["listen"] || legacy_scope(config["listen_address"])

    transports =
      Map.new(@transports, fn {protocol, _name, port} ->
        transport = get_in(config, ["transports", protocol]) || %{}
        legacy_port = if protocol in ~w(udp tcp), do: config["port"], else: nil

        {protocol,
         Map.merge(scope_params(transport["listen"], "inherit"), %{
           "enabled" => to_string(Map.get(transport, "enabled", protocol in ~w(udp tcp))),
           "port" => to_string(transport["port"] || legacy_port || port),
           "certificate_id" => transport["certificate_id"] || ""
         })}
      end)

    Map.merge(scope_params(listen, "all"), %{
      "desired_state" => (service && service["desired_state"]) || "running",
      "transports" => transports
    })
  end

  def config(params, previous) do
    submitted = if is_map(params["transports"]), do: params["transports"], else: %{}

    transports =
      Enum.reduce_while(@transports, {:ok, %{}}, fn {protocol, label, _}, {:ok, acc} ->
        case transport(submitted[protocol]) do
          {:ok, value} -> {:cont, {:ok, Map.put(acc, protocol, value)}}
          :error -> {:halt, {:error, "#{label} port must be an integer"}}
        end
      end)

    with {:ok, transports} <- transports do
      {:ok,
       Map.merge(Map.take(previous, @policy_fields), %{
         "listen" => scope(params),
         "transports" => transports
       })}
    end
  end

  def listener_label(%{"listen" => %{"mode" => "specific", "addresses" => addresses}}),
    do: Enum.join(addresses, ", ")

  def listener_label(%{"listen" => %{"mode" => mode}}),
    do: Enum.find_value(@modes, "", fn {label, key} -> if key == mode, do: label end)

  def listener_label(%{"listen_address" => ip, "port" => port}), do: "#{ip}:#{port}"

  def listener_summary(%{"listen" => listen, "transports" => transports}) do
    entries =
      for {protocol, label, _} <- @transports,
          %{"enabled" => true, "port" => port} = options <- [transports[protocol]] do
        address = listener_label(%{"listen" => options["listen"] || listen})
        "#{label} #{address}, port #{port}"
      end

    if entries == [], do: "No enabled protocols", else: Enum.join(entries, " · ")
  end

  def listener_summary(config), do: listener_label(config)

  defp scope_params(nil, default), do: %{"mode" => default, "addresses" => ""}

  defp scope_params(scope, default) do
    %{
      "mode" => scope["mode"] || default,
      "addresses" => Enum.join(scope["addresses"] || [], "\n")
    }
  end

  defp legacy_scope("0.0.0.0"), do: %{"mode" => "all_ipv4"}
  defp legacy_scope(nil), do: nil
  defp legacy_scope(ip), do: %{"mode" => "specific", "addresses" => [ip]}

  defp scope(%{"mode" => "specific", "addresses" => text}) when is_binary(text) do
    addresses = String.split(text, ~r/[\n\r,\s]+/, trim: true)
    %{"mode" => "specific", "addresses" => addresses}
  end

  defp scope(params), do: %{"mode" => params["mode"]}

  defp transport(%{"port" => port} = params) when is_binary(port) do
    with {port, ""} <- Integer.parse(port) do
      config = %{"port" => port, "enabled" => params["enabled"] == "true"}

      config =
        if params["mode"] == "inherit", do: config, else: Map.put(config, "listen", scope(params))

      {:ok,
       if(params["certificate_id"] in [nil, ""],
         do: config,
         else: Map.put(config, "certificate_id", params["certificate_id"])
       )}
    else
      _ -> :error
    end
  end

  defp transport(_), do: :error

  attr :form, Phoenix.HTML.Form, required: true
  attr :intent, :string, required: true
  attr :certificates, :list, required: true

  def editor(assigns) do
    assigns = assign(assigns, modes: @modes, protocols: @transports)

    ~H"""
    <.form
      for={@form}
      id="service-form"
      phx-submit="save_service"
      phx-change="validate_service"
      class="grid gap-4"
    >
      <input type="hidden" name="_submission" value={@intent} />
      <input type="hidden" name="service[desired_state]" value="stopped" />
      <label class="form-control">
        <span class="label">Enable DNS service</span>
        <input
          type="checkbox"
          class="checkbox"
          name="service[desired_state]"
          value="running"
          checked={@form[:desired_state].value == "running"}
        />
      </label>
      <.listening_scope
        name="service"
        label="Default listening IPs"
        params={@form.params}
        modes={@modes}
      />
      <fieldset
        :for={{protocol, label, _} <- @protocols}
        class="grid gap-4 border border-outline-variant rounded-lg p-4"
        id={"dns-#{protocol}-settings"}
      >
        <legend>{label}</legend>
        <% current = get_in(@form.params, ["transports", protocol]) || %{} %>
        <% name = "service[transports][#{protocol}]" %>
        <input type="hidden" name={"#{name}[enabled]"} value="false" />
        <label class="form-control">
          <span class="label">Enable {label}</span>
          <input
            type="checkbox"
            class="checkbox"
            name={"#{name}[enabled]"}
            value="true"
            checked={current["enabled"] == "true"}
          />
        </label>
        <label class="form-control">
          <span class="label">Port</span>
          <input
            type="number"
            class="input input-bordered"
            name={"#{name}[port]"}
            value={current["port"]}
            min="1"
            max="65535"
            required
          />
        </label>
        <.listening_scope
          name={name}
          label={"#{label} listening IPs"}
          params={current}
          modes={[{"Use default listening IPs", "inherit"} | @modes]}
        />
        <label :if={protocol in ~w(dot doq doh)} class="form-control">
          <span class="label">Certificate</span>
          <select class="select select-bordered" name={"#{name}[certificate_id]"}>
            <option value="">Select a certificate</option>
            <option
              :for={item <- @certificates}
              value={item.id}
              selected={item.id == current["certificate_id"]}
            >
              {item.name}
            </option>
          </select>
        </label>
      </fieldset>
      <button class="btn btn-primary" type="submit" phx-disable-with="Saving…">Save DNS settings</button>
    </.form>
    """
  end

  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :params, :map, required: true
  attr :modes, :list, required: true

  defp listening_scope(assigns) do
    ~H"""
    <label class="form-control">
      <span class="label">{@label}</span>
      <select class="select select-bordered" name={"#{@name}[mode]"}>
        <option :for={{label, value} <- @modes} value={value} selected={value == @params["mode"]}>
          {label}
        </option>
      </select>
    </label>
    <label :if={@params["mode"] == "specific"} class="form-control">
      <span class="label">IPv4 or IPv6 addresses (one per line)</span>
      <textarea class="textarea textarea-bordered" name={"#{@name}[addresses]"} rows="3" required>{@params["addresses"]}</textarea>
    </label>
    """
  end
end
